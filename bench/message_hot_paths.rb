#!/usr/bin/env ruby
# frozen_string_literal: true
require "bundler/setup"
require "optparse"
require "rack/mock"
require "digest"
require "tmpdir"
require_relative "../app"

options = {seed: "tmp/bench-seed", iterations: 100, output: "bench/results/hot-paths.json"}
OptionParser.new do |parser|
  parser.on("--seed PATH") { |v| options[:seed] = v }
  parser.on("--iterations N", Integer) { |v| options[:iterations] = v }
  parser.on("--output PATH") { |v| options[:output] = v }
end.parse!
abort "iterations must be positive" unless options[:iterations].positive?
labels = JSON.parse(File.read(File.join(options[:seed], "labels.json")))
abort "Use an isolated benchmark seed" unless labels["fixture"] == "campfire-roda-benchmark-v1"
work = Dir.mktmpdir("campfire-hot-paths-")
db = nil
at_exit { db&.disconnect; FileUtils.remove_entry(work) if File.directory?(work) }
Campfire::Database.snapshot(File.join(options[:seed], "campfire.sqlite3"), File.join(work, "campfire.sqlite3"))
db = Campfire::Database.connect(path: File.join(work, "campfire.sqlite3"))
Campfire::Database.migrate(db)
container = Campfire::Container.new(db: db, upload_root: File.join(options[:seed], "files"))
app = Campfire::App.build(container)
client = Rack::MockRequest.new(app)
cookies = {}
merge_cookies = lambda do |response|
  Array(response.headers["set-cookie"]).each do |header|
    key, value = header.split(";", 2).first.split("=", 2)
    cookies[key] = value
  end
end
cookie = -> { cookies.map { |k, v| "#{k}=#{v}" }.join("; ") }
response = client.get("/session/new")
merge_cookies.call(response)
token = CGI.unescapeHTML(response.body[/<meta name="csrf-token" content="([^"]+)"/, 1].to_s)
response = client.post("/session", "HTTP_COOKIE" => cookie.call, "HTTP_SEC_FETCH_SITE" => "same-origin", params: {
  email_address: labels.fetch("emails.david"), password: labels.fetch("passwords.all"), authenticity_token: token})
raise "Login failed: #{response.status}" unless response.status == 302
merge_cookies.call(response)

class QueryCounter
  attr_accessor :count
  def initialize = @count = 0
  def info(*) = @count += 1
end
counter = QueryCounter.new
db.loggers << counter
paths = {room: "/rooms/#{labels.fetch('rooms.watercooler')}",
  messages: "/rooms/#{labels.fetch('rooms.watercooler')}/messages?before=#{labels.fetch('messages.busy_060')}",
  sidebar: "/users/me/sidebar", search: "/searches?q=coffee"}
clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
results = {}
paths.each do |name, path|
  20.times { client.get(path, "HTTP_COOKIE" => cookie.call) }
  times, allocations, queries, hashes = [], [], [], []
  bytes = nil
  options[:iterations].times do
    counter.count = 0
    allocated = GC.stat(:total_allocated_objects)
    started = clock.call
    response = client.get(path, "HTTP_COOKIE" => cookie.call)
    times << (clock.call - started) * 1000
    allocations << GC.stat(:total_allocated_objects) - allocated
    queries << counter.count
    raise "#{path}: HTTP #{response.status}" unless response.status == 200
    # Keep historical token/nonce normalization; current forms are token-free.
    normalized = response.body.gsub(/(name="(?:csrf-token|authenticity_token)" (?:content|value)=")[^"]+/, '\1[csrf]')
      .gsub(/(nonce=")[^"]+/, '\1[nonce]').gsub(/(name="csp-nonce" content=")[^"]+/, '\1[nonce]')
    hashes << Digest::SHA256.hexdigest(normalized)
    bytes = response.body.bytesize
  end
  results[name] = {milliseconds: times, allocations: allocations, queries: queries, body_sha256: hashes.uniq, body_bytes: bytes,
    median_ms: times.sort[times.length / 2], median_allocations: allocations.sort[allocations.length / 2]}
  raise "#{name} changed while reading" unless hashes.uniq.length == 1
end
db.loggers.clear
adapter = Object.new
captured = []
adapter.define_singleton_method(:broadcast) { |stream, payload| captured << [stream, payload] }
fanout = Campfire::UnreadFanout.new(adapter)
ids = (1..1000).to_a
times, allocations = [], []
options[:iterations].times do
  captured.clear
  allocated = GC.stat(:total_allocated_objects)
  started = clock.call
  fanout.broadcast(labels.fetch("rooms.watercooler"), ids)
  times << (clock.call - started) * 1000
  allocations << GC.stat(:total_allocated_objects) - allocated
  raise "Invalid fanout" unless captured.length == 1000 && captured.all? { |_, payload| JSON.parse(payload) == {"roomId" => labels.fetch("rooms.watercooler")} }
end
results[:unread_fanout_1000] = {milliseconds: times, allocations: allocations, median_ms: times.sort[times.length / 2]}
output = {ruby: RUBY_DESCRIPTION, roda: Roda::RodaVersion, sequel: Sequel::VERSION, iterations: options[:iterations],
  cache: {response_mb: ENV.fetch("CAMPFIRE_RESPONSE_CACHE_MB", "64"), fragment_mb: ENV.fetch("CAMPFIRE_FRAGMENT_CACHE_MB", "64")},
  query_accounting: "Sequel statements; excludes the separate SQLite cache observer", csrf: "Fetch Metadata and Origin", fixture: labels, results: results}
FileUtils.mkdir_p(File.dirname(options[:output]))
File.write(options[:output], JSON.pretty_generate(output) + "\n")
results.each { |name, result| puts "%s: %.3f ms, %s queries, %s allocations" % [name, result[:median_ms], result[:queries]&.uniq&.join(",") || "—", result[:median_allocations] || result[:allocations].sort[result[:allocations].length / 2]] }
puts "Saved #{options[:output]}"
db.disconnect
