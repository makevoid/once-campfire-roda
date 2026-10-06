#!/usr/bin/env ruby
# frozen_string_literal: true
# Mutates disposable fixtures only. This is a semantic check, not a load test.
require "bundler/setup"
require "json"
require "optparse"
require "nokogiri"
require "sqlite3"
require "securerandom"
require "time"
require "fileutils"
require_relative "http_client"

class ParitySession
  attr_reader :csrf

  def initialize(url, labels)
    @base = URI(url)
    @cookies = BenchmarkHTTPClient.new(url).login(labels).split("; ").to_h { |pair| pair.split("=", 2) }
    get("/rooms/#{labels.fetch('rooms.watercooler')}")
  end

  def get(path) = request("GET", path)

  def request(method, path, params: {}, csrf: true, accept: "text/html")
    request = Net::HTTP.const_get(method.capitalize).new(path)
    request["Cookie"] = @cookies.map { |key, value| "#{key}=#{value}" }.join("; ")
    request["Accept"] = accept
    request["Accept-Encoding"] = "identity"
    unless method == "GET"
      request["Origin"] = @base.to_s
      request["Sec-Fetch-Site"] = "same-origin"
      request["X-CSRF-Token"] = @csrf if csrf
      request.set_form_data(params)
    end
    response = Net::HTTP.start(@base.host, @base.port, nil, read_timeout: 15) { |http| http.request(request) }
    response.get_fields("set-cookie").to_a.each do |header|
      key, value = header.split(";", 2).first.split("=", 2)
      @cookies[key] = value
    end
    token = Nokogiri::HTML(response.body.to_s, nil, "UTF-8").at_css('meta[name="csrf-token"]')&.[]("content")
    @csrf = token if token
    response
  end
end

options = {output: "bench/results/parity.json"}
OptionParser.new do |parser|
  parser.banner = "Usage: bundle exec ruby bench/verify_parity.rb --rails-url URL --roda-url URL --rails-database PATH --roda-database PATH --labels PATH [--output PATH]"
  %i[rails_url roda_url rails_database roda_database labels output].each do |key|
    parser.on("--#{key.to_s.tr('_', '-')} VALUE") { |value| options[key] = value }
  end
end.parse!
%i[rails_url roda_url rails_database roda_database labels].each { |key| abort "Missing #{key}" unless options[key] }
%i[rails_url roda_url].each do |key|
  uri = URI(options[key])
  abort "Use isolated loopback HTTP servers" unless uri.scheme == "http" && %w[127.0.0.1 localhost].include?(uri.host)
end
labels = JSON.parse(File.read(options[:labels]))
abort "Use disposable benchmark fixtures" unless labels["fixture"] == "campfire-roda-benchmark-v1"
report = {checks: [], limitations: "Checks shared text-message behavior; not full UI, protocol, media, or delivery parity."}
report[:observed_statuses] = {}

check = lambda do |name, condition|
  raise "Parity check failed: #{name}" unless condition
  report[:checks] << name
end
ok = ->(response) { %w[200 201 204 302 303].include?(response.code) }
blocked = ->(response) { %w[302 303 401 403 404 422].include?(response.code) }
document = ->(response) { Nokogiri::HTML(response.body.to_s, nil, "UTF-8") }
records = lambda do |response, side|
  document.call(response).css(".message[data-message-id]").map do |node|
    body = node.at_css(side == "rails" ? '[data-messages-target="body"]' : ".body")
    raise "Missing rendered message body" unless body
    author = node.at_css(side == "rails" ? '[data-reply-target="author"]' : "header a")
    boosts = if side == "rails"
      node.css(".boost-item").map do |boost|
        content = boost.at_css('[data-boost-delete-target="content"]').text
        name = boost.at_css("[aria-label]")["aria-label"].delete_suffix(" boosted #{content}")
        [name, content]
      end
    else
      node.css(".boosts .boost").map { |boost| [boost["title"], boost.text] }
    end
    {id: node["data-message-id"].to_i, author: author.text.strip,
      text: body.text.gsub(/\s+/, " ").strip,
      formatting: body.css("strong,em,b,i,a").map { |element| [element.name, element.text, element["href"]] },
      timestamp: Time.iso8601(node.at_css("time")["datetime"]).utc.iso8601,
      boosts: boosts.sort}
  end
end
sidebar = lambda do |response|
  doc = document.call(response)
  lists = %w[shared_rooms direct_rooms].to_h do |id|
    [id, doc.css("##{id} a[href]").filter_map do |link|
      match = link["href"].match(%r{/rooms/(\d+)\z})
      [match[1].to_i, link["class"].to_s.split.include?("unread")] if match
    end]
  end
  lists["suggested_users"] = doc.css('a[href*="user_id="], form[action*="user_ids"]').map do |node|
    query = URI(node["href"] || node["action"]).query
    URI.decode_www_form(query).find { |key, _| %w[user_id user_ids[]].include?(key) }.last.to_i
  end.sort
  lists
end

databases = %w[rails roda].to_h do |side|
  [side, SQLite3::Database.new(options.fetch("#{side}_database".to_sym), readonly: true, results_as_hash: true)]
end
databases.each_value { |db| db.busy_timeout = 5000 }
sessions = %w[rails roda].to_h { |side| [side, ParitySession.new(options.fetch("#{side}_url".to_sym), labels)] }
room = labels.fetch("rooms.watercooler")
cursor = labels.fetch("messages.busy_060")
paths = {room: "/rooms/#{room}", earlier: "/rooms/#{room}/messages?before=#{cursor}",
  after: "/rooms/#{room}/messages?after=40", permalink: "/rooms/#{room}/@1000", search: "/searches?q=coffee"}
paths.each do |name, path|
  responses = sessions.transform_values { |session| session.get(path) }
  check.call("#{name}: HTTP 200", responses.values.all? { |response| response.code == "200" })
  normalized = responses.map { |side, response| records.call(response, side) }
  if normalized[0] != normalized[1]
    index = normalized[0].each_index.find { |i| normalized[0][i] != normalized[1][i] }
    warn JSON.pretty_generate(path: path, rails: normalized[0][index || 0], roda: normalized[1][index || 0])
  end
  check.call("#{name}: identical ordered IDs, text, formatting, authors, timestamps and boosts", normalized[0] == normalized[1] && !normalized[0].empty?)
end
sidebars = sessions.transform_values { |session| sidebar.call(session.get('/users/me/sidebar')) }
warn JSON.pretty_generate(sidebars) if sidebars.values.uniq.length != 1
check.call("sidebar: identical room order, unread flags and suggested users", sidebars.values.uniq.length == 1)
%w[rails roda].each do |side|
  uri = URI(options.fetch("#{side}_url".to_sym) + "/rooms/#{room}")
  response = Net::HTTP.start(uri.host, uri.port, nil) { |http| http.get(uri.request_uri) }
  check.call("#{side}: anonymous room access requires login", %w[302 303 401 403].include?(response.code))
end
direct = databases.fetch("rails").get_first_value("SELECT id FROM rooms WHERE type = 'Rooms::Direct' ORDER BY id LIMIT 1")
sessions.each do |side, session|
  response = session.request("PATCH", "/rooms/#{direct}/involvement", params: {involvement: "invisible"})
  check.call("#{side}: hide direct room", ok.call(response))
end
check.call("hidden direct: identical sidebar and excluded participant suggestions",
  sessions.values.map { |session| sidebar.call(session.get('/users/me/sidebar')) }.uniq.length == 1)

shared_token = "parity-#{SecureRandom.hex(8)}"
report[:mutations] = {}
sessions.each do |side, admin|
  db = databases.fetch(side)
  user = db.get_first_row("SELECT id, email_address FROM users WHERE role = 0 ORDER BY id LIMIT 1")
  other = db.get_first_row("SELECT id, email_address FROM users WHERE role = 0 ORDER BY id LIMIT 1 OFFSET 1")
  member = ParitySession.new(options.fetch("#{side}_url".to_sym), labels.merge("emails.david" => user.fetch("email_address")))
  outsider = ParitySession.new(options.fetch("#{side}_url".to_sym), labels.merge("emails.david" => other.fetch("email_address")))
  post_path = "/rooms/#{room}/messages"
  count = db.get_first_value("SELECT COUNT(*) FROM messages")
  response = member.request("POST", post_path, csrf: false, params: {"message[body]" => "csrf-rejected"})
  check.call("#{side}: missing CSRF rejected without a write", blocked.call(response) && db.get_first_value("SELECT COUNT(*) FROM messages") == count)
  response = member.request("POST", post_path, accept: "text/vnd.turbo-stream.html", params: {
    "message[body]" => "<p>parityneedle <strong>coffee</strong> &amp; tea</p>", "message[client_message_id]" => shared_token})
  check.call("#{side}: authenticated message create", ok.call(response))
  message = db.get_first_row("SELECT * FROM messages WHERE client_message_id = ?", [shared_token])
  check.call("#{side}: exactly one created message", !!message && db.get_first_value("SELECT COUNT(*) FROM messages") == count + 1)
  id = message.fetch("id")
  edit_path = "/rooms/#{room}/messages/#{id}"
  check.call("#{side}: created message appears in search", records.call(member.get('/searches?q=parityneedle'), side).any? { |r| r[:id] == id })
  response = outsider.request("PATCH", edit_path, params: {"message[body]" => "unauthorized"})
  check.call("#{side}: non-author edit rejected", response.code == "403")
  response = member.request("PATCH", edit_path, params: {"message[body]" => "<p>replacementneedle <em>tea</em></p>"})
  check.call("#{side}: author edit succeeds", ok.call(response))
  check.call("#{side}: search index removes old text", records.call(member.get('/searches?q=parityneedle'), side).none? { |r| r[:id] == id })
  edited = records.call(member.get('/searches?q=replacementneedle'), side).find { |r| r[:id] == id }
  check.call("#{side}: edited text and formatting rendered", edited && edited[:text] == "replacementneedle tea" && edited[:formatting] == [["em", "tea", nil]])
  response = member.request("POST", "/messages/#{id}/boosts", params: {"boost[content]" => "☕"})
  check.call("#{side}: create boost", ok.call(response))
  boost = db.get_first_row("SELECT * FROM boosts WHERE message_id = ?", [id])
  boost_path = "/messages/#{id}/boosts/#{boost.fetch('id')}"
  response = admin.request("DELETE", boost_path, accept: "text/vnd.turbo-stream.html")
  check.call("#{side}: administrator cannot remove another user's boost", %w[403 404].include?(response.code) && db.get_first_value("SELECT COUNT(*) FROM boosts WHERE id = ?", [boost.fetch('id')]) == 1)
  response = member.request("DELETE", boost_path, accept: "text/vnd.turbo-stream.html")
  check.call("#{side}: booster can remove own boost", ok.call(response) && db.get_first_value("SELECT COUNT(*) FROM boosts WHERE id = ?", [boost.fetch('id')]) == 0)
  response = member.request("DELETE", edit_path, accept: "text/vnd.turbo-stream.html")
  check.call("#{side}: author deletes message and search entry", ok.call(response) && !db.get_first_row("SELECT id FROM messages WHERE id = ?", [id]) && records.call(member.get('/searches?q=replacementneedle'), side).empty?)

  admin_id = db.get_first_value("SELECT id FROM users WHERE email_address = ?", [labels.fetch('emails.david')])
  response = admin.request("POST", "/rooms/closeds", params: [["room[name]", "Parity private"], ["user_ids[]", admin_id], ["user_ids[]", user.fetch('id')]])
  check.call("#{side}: private room created", %w[302 303].include?(response.code))
  private_id = db.get_first_value("SELECT id FROM rooms WHERE name = 'Parity private'")
  admin.get("/rooms/#{private_id}")
  response = admin.request("POST", "/rooms/#{private_id}/messages", accept: "text/vnd.turbo-stream.html", params: {
    "message[body]" => "<p>privacyneedle coffee</p>", "message[client_message_id]" => "#{shared_token}-private"})
  check.call("#{side}: private message created", ok.call(response))
  private_message = db.get_first_value("SELECT id FROM messages WHERE client_message_id = ?", ["#{shared_token}-private"])
  check.call("#{side}: private-room member sees message", records.call(member.get("/rooms/#{private_id}"), side).any? { |r| r[:id] == private_message })
  check.call("#{side}: non-member cannot read private room", blocked.call(outsider.get("/rooms/#{private_id}")))
  check.call("#{side}: non-member search excludes private message", records.call(outsider.get('/searches?q=privacyneedle'), side).empty?)
  check.call("#{side}: cross-room pagination cursor rejected", %w[400 403 404].include?(outsider.get("/rooms/#{room}/messages?before=#{private_message}").code))
  response = outsider.request("POST", "/rooms/#{private_id}/messages", accept: "text/vnd.turbo-stream.html", params: {"message[body]" => "unauthorized-private"})
  # Error representations differ; check persisted state as well as recording status.
  report[:observed_statuses]["#{side}_unauthorized_private_write"] = response.code.to_i
  check.call("#{side}: non-member private write creates no message", db.get_first_value("SELECT COUNT(*) FROM messages WHERE room_id = ?", [private_id]) == 1)
  report[:mutations][side] = {member_id: user.fetch('id'), private_room_id: private_id, private_message_id: private_message}
end
report[:passed] = report[:checks].length
FileUtils.mkdir_p(File.dirname(options[:output]))
File.write(options[:output], JSON.pretty_generate(report) + "\n")
puts "#{report[:passed]} live parity checks passed. #{report[:limitations]}"
databases.each_value(&:close)
