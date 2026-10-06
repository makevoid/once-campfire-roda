#!/usr/bin/env ruby
# frozen_string_literal: true
# HTTP traffic uses the original Rails standard-library load generator.
require "bundler/setup"
require "optparse"
require "json"
require "fileutils"
require "socket"
require "rbconfig"
require "tmpdir"
require_relative "../lib/campfire/database"
require_relative "http_client"

options = {seed: "tmp/bench-seed", url: nil, baseline_url: nil, baseline_labels: nil,
  duration: 3.0, warmup: 2.0, rounds: 2, concurrencies: "1,16", paths: "room,messages,sidebar,search", output: "bench/results/http"}
OptionParser.new do |parser|
  parser.banner = "Usage: ruby bench/compare_http.rb [options] (starts an isolated Roda server by default)"
  options.each do |key, default|
    type = default.is_a?(Integer) ? Integer : default.is_a?(Float) ? Float : String
    parser.on("--#{key.to_s.tr('_', '-')} VALUE", type) { |v| options[key] = v }
  end
end.parse!
abort "duration/warmup must be positive; rounds must be positive and even" unless options[:duration].positive? && options[:warmup].positive? && options[:rounds].positive? && options[:rounds].even?
concurrencies = options[:concurrencies].split(",").map { |v| Integer(v) }
abort "concurrencies must be positive" unless concurrencies.all?(&:positive?) && !concurrencies.empty?
labels = JSON.parse(File.read(File.join(options[:seed], "labels.json")))
abort "Use an isolated benchmark seed" unless labels["fixture"] == "campfire-roda-benchmark-v1"
selected = options[:paths].split(",")
abort "Unknown or duplicate paths" unless (selected - %w[room messages sidebar search]).empty? && selected.uniq == selected && !selected.empty?
FileUtils.mkdir_p(options[:output])
root = File.expand_path("..", __dir__)
pid = nil
work = Dir.mktmpdir("campfire-http-")
begin
  unless options[:url]
    Campfire::Database.snapshot(File.join(options[:seed], "campfire.sqlite3"), File.join(work, "campfire.sqlite3"))
    port = TCPServer.open("127.0.0.1", 0) { |socket| socket.addr[1] }
    options[:url] = "http://127.0.0.1:#{port}"
    env = {"DATABASE_PATH" => File.join(work, "campfire.sqlite3"), "UPLOAD_ROOT" => File.expand_path(File.join(options[:seed], "files")), "RACK_ENV" => "production",
      "DISABLE_SSL" => "true", "SESSION_SECRET" => "isolated-benchmark-fixture-secret-" * 4,
      "HOST" => "127.0.0.1", "PORT" => port.to_s, "WEB_CONCURRENCY" => "0", "MAX_THREADS" => "5", "DB_POOL" => "5"}
    pid = Process.spawn(env, "bundle", "exec", "puma", "-C", "config/puma.rb", chdir: root,
      out: File.join(options[:output], "server.log"), err: [:child, :out])
  end
  endpoints = {"roda" => [options[:url], labels]}
  if options[:baseline_url]
    baseline = options[:baseline_labels] ? JSON.parse(File.read(options[:baseline_labels])) : labels
    endpoints["baseline"] = [options[:baseline_url], baseline]
  end
  clients = endpoints.to_h do |name, (url, fixture)|
    client = BenchmarkHTTPClient.new(url)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    until client.ready?
      raise "#{name} did not start; check #{options[:output]}/server.log" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end
    [name, [client, client.login(fixture), fixture]]
  end
  options[:rounds].times do |round|
    order = round.even? ? clients.keys : clients.keys.reverse
    order.each do |name|
      client, cookie, fixture = clients.fetch(name)
      paths = {"room" => "/rooms/#{fixture.fetch('rooms.watercooler')}",
        "messages" => "/rooms/#{fixture.fetch('rooms.watercooler')}/messages?before=#{fixture.fetch('messages.busy_060')}",
        "sidebar" => "/users/me/sidebar", "search" => "/searches?q=coffee"}
      results = {}
      selected.each do |label|
        path = paths.fetch(label)
        client.measure(path, cookie, concurrency: 1, duration: options[:warmup])
        concurrencies.each do |concurrency|
          result = client.measure(path, cookie, concurrency: concurrency, duration: options[:duration])
          results["#{label}_#{concurrency}"] = result
          puts "%s round %d %s c=%d: %.0f req/s, p50 %.2f ms, p95 %.2f ms, %d bytes" % [name, round + 1, label, concurrency, result[:rps], result[:latency_ms][:p50], result[:latency_ms][:p95], result[:avg_bytes]]
          $stdout.flush
        end
      end
      File.write(File.join(options[:output], "#{name}-#{round + 1}.json"), JSON.pretty_generate({client_ruby: RUBY_DESCRIPTION, options: options, fixture: fixture, results: results}) + "\n")
    end
  end
ensure
  if pid
    Process.kill("TERM", pid) rescue Errno::ESRCH
    Process.wait(pid) rescue Errno::ECHILD
  end
  FileUtils.remove_entry(work)
end
