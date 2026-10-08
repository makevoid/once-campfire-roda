#!/usr/bin/env ruby
# frozen_string_literal: true
# Live, disposable-fixture HTTP and WebSocket checks. Never point at real data.
require "bundler/setup"
require "json"
require "nokogiri"
require "websocket/driver"
require "socket"
require "io/wait"
require_relative "http_client"

class FrontendSession
  attr_reader :base, :csrf
  def initialize(base, labels)
    @base = URI(base)
    @cookies = BenchmarkHTTPClient.new(base).login(labels).split("; ").to_h { |part| part.split("=", 2) }
  end
  def cookie = @cookies.map { |key, value| "#{key}=#{value}" }.join("; ")
  def request(path, method: :get, values: nil, accept: "text/html")
    klass = {get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete}.fetch(method)
    req = klass.new(path)
    req["Cookie"], req["Accept"], req["Origin"] = cookie, accept, base.to_s
    req["X-CSRF-Token"] = @csrf if @csrf
    req["Sec-Fetch-Site"] = "same-origin" unless method == :get
    req.set_form_data(values) if values
    response = Net::HTTP.start(base.host, base.port, nil, open_timeout: 3, read_timeout: 10) { |http| http.request(req) }
    response.get_fields("set-cookie").to_a.each do |header|
      key, value = header.split(";", 2).first.split("=", 2)
      @cookies[key] = value
    end
    @csrf = CGI.unescapeHTML(response.body[/<meta name="csrf-token" content="([^"]+)"/, 1]) if response.body.to_s.include?('name="csrf-token"')
    response
  end
end

class FrontendSocket
  attr_reader :url, :packets
  def initialize(session)
    @url = "ws://#{session.base.host}:#{session.base.port}/cable"
    @io = TCPSocket.new(session.base.host, session.base.port)
    @packets = []
    @driver = WebSocket::Driver.client(self, protocols: ["actioncable-v1-json"])
    @driver.set_header("Cookie", session.cookie)
    @driver.set_header("Origin", session.base.to_s)
    @driver.on(:message) { |event| @packets << JSON.parse(event.data) }
    @driver.on(:error) { |event| raise event.message }
    @driver.start
    wait { |packet| packet["type"] == "welcome" }
  end
  def write(bytes) = @io.write(bytes)
  def subscribe(channel, **params)
    identifier = JSON.generate({channel: channel}.merge(params))
    @driver.text(JSON.generate(command: "subscribe", identifier: identifier))
    wait { |packet| packet["identifier"] == identifier && packet["type"] == "confirm_subscription" }
    identifier
  end
  def wait
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 8
    loop do
      index = @packets.index { |packet| yield(packet) }
      return @packets.delete_at(index) if index
      raise "Timed out waiting for WebSocket packet" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      @driver.parse(@io.readpartial(65_536)) if @io.wait_readable(0.1)
    end
  end
  def close
    @driver.close
    @io.close
  end
end

base = ENV.fetch("BASE_URL", "http://127.0.0.1:9396")
labels = JSON.parse(File.read(ARGV.fetch(0)))
abort "Use a disposable fixture" unless labels["fixture"] == "campfire-roda-benchmark-v1"
abort "Use a loopback HTTP server" unless URI(base).scheme == "http" && %w[localhost 127.0.0.1].include?(URI(base).host)
checks = 0
check = ->(value, name) { raise name unless value; checks += 1 }
session = FrontendSession.new(base, labels)
room = labels.fetch("rooms.watercooler")
response = session.request("/rooms/#{room}")
check.call(response.code == "200", "room")
doc = Nokogiri::HTML5(response.body)
imports = JSON.parse(doc.at_css('script[type="importmap"]').text).fetch("imports")
check.call(imports.key?("initializers") && imports.key?("controllers"), "directory index imports")
(imports.values + doc.css('link[rel="stylesheet"]').map { |node| node["href"] }).uniq.each do |path|
  check.call(session.request(path).code == "200", "asset #{path}")
end
%W[/users/me/sidebar /users/me/profile /account/edit /account/bots/new /rooms/opens/new /rooms/closeds/new /rooms/directs/new /searches?q=coffee /autocompletable/users?room_id=#{room}&filter=David].each do |path|
  check.call(session.request(path).code == "200", path)
end
session.request("/rooms/#{room}")
socket = FrontendSocket.new(session)
socket.subscribe("HeartbeatChannel")
stream = doc.at_css('turbo-cable-stream-source[channel="RoomMessagesChannel"]')["signed-stream-name"]
socket.subscribe("RoomMessagesChannel", signed_stream_name: stream)
socket.subscribe("PresenceChannel", room_id: room)
client_id = "live-test-#{Time.now.to_i}"
response = session.request("/rooms/#{room}/messages", method: :post, accept: "text/vnd.turbo-stream.html", values: {"message[body]" => "Live Erubi frontend test", "message[client_message_id]" => client_id})
check.call(response.code == "200", "message POST #{response.code}")
id = Nokogiri::HTML5.fragment(response.body).at_css("[data-message-id]")["data-message-id"]
check.call(response.body.include?("id=\"message_#{id}\""), "HTTP Turbo append")
packet = socket.wait { |item| item["message"].is_a?(String) && item["message"].include?("id=\"message_#{id}\"") }
check.call(packet["message"].include?('action="append"'), "WebSocket Turbo append")
response = session.request("/rooms/#{room}/messages/#{id}", method: :delete, accept: "text/vnd.turbo-stream.html")
check.call(response.code == "200", "message DELETE")
packet = socket.wait { |item| item["message"].is_a?(String) && item["message"].include?('action="remove"') }
check.call(packet["message"].include?("message_#{id}"), "WebSocket Turbo remove")
socket.close
puts JSON.pretty_generate(checks: checks, status: "passed", rendering: "Erubi", transport: "HTTP and WebSocket")
