# frozen_string_literal: true
require "json"
require "sqlite3"
require "nokogiri"
require_relative "../http_client"

original, imported, labels_path, rails_url, roda_url, output = ARGV
labels = JSON.parse(File.read(labels_path))
source = SQLite3::Database.new(original, readonly: true, results_as_hash: true)
target = SQLite3::Database.new(imported, readonly: true, results_as_hash: true)
counts = {}
%w[accounts users rooms memberships messages boosts searches bans].each do |table|
  before = source.execute("SELECT * FROM #{table} ORDER BY id")
  after = target.execute("SELECT * FROM #{table} ORDER BY id")
  raise "Fixture differs in #{table}" unless before == after
  counts[table] = before.length
end
room = labels.fetch("rooms.watercooler")
cursor = labels.fetch("messages.busy_060")
paths = {"room" => "/rooms/#{room}", "messages" => "/rooms/#{room}/messages?before=#{cursor}",
  "sidebar" => "/users/me/sidebar", "search" => "/searches?q=coffee"}
expected = {
  "room" => source.execute("SELECT id FROM messages WHERE room_id = ? ORDER BY created_at DESC, id DESC LIMIT 40", [room]).map { |r| r.fetch("id") }.sort,
  "messages" => source.execute("SELECT id FROM messages WHERE room_id = ? AND created_at < (SELECT created_at FROM messages WHERE id = ?) ORDER BY created_at DESC, id DESC LIMIT 40", [room, cursor]).map { |r| r.fetch("id") }.sort,
  "search" => source.execute("SELECT id FROM messages WHERE plain_text LIKE '%coffee%' ORDER BY id DESC LIMIT 100").map { |r| r.fetch("id") }.sort
}
report = {fixture_counts: counts, responses: {}}
{"rails" => rails_url, "roda" => roda_url}.each do |name, url|
  client = BenchmarkHTTPClient.new(url)
  cookie = client.login(labels)
  report[:responses][name] = {}
  uri = URI(url)
  Net::HTTP.start(uri.host, uri.port, nil) do |http|
    paths.each do |label, path|
      response = http.get(path, "Cookie" => cookie, "Accept-Encoding" => "identity")
      raise "#{name} #{label}: HTTP #{response.code}" unless response.code == "200"
      html = Nokogiri::HTML(response.body)
      ids = html.css(".message[data-message-id]").map { |node| Integer(node["data-message-id"]) }.sort
      raise "#{name} #{label}: unexpected messages #{ids}" if expected.key?(label) && ids != expected.fetch(label)
      report[:responses][name][label] = {status: response.code, bytes: response.body.bytesize, message_ids: ids}
    end
  end
end
source.close
target.close
File.write(output, JSON.pretty_generate(report) + "\n")
puts "Fixtures identical; both apps returned the expected 40 room, 40 earlier, and 100 search messages with HTTP 200."
