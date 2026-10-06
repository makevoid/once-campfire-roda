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
require_relative "parallel_http_client"
require_relative "process_sampler"

options = {seed: "tmp/bench-seed", url: nil, baseline_url: nil, baseline_labels: nil,
  duration: 3.0, warmup: 2.0, rounds: 2, concurrencies: "1,16", paths: "room,messages,sidebar,search", output: "bench/results/http",
  workers: 0, threads: 5, db_pool: 5, warmup_concurrency: 1, client_processes: 1}
OptionParser.new do |parser|
  parser.banner = "Usage: ruby bench/compare_http.rb [options] (starts an isolated Roda server by default)"
  options.each do |key, default|
    type = default.is_a?(Integer) ? Integer : default.is_a?(Float) ? Float : String
    parser.on("--#{key.to_s.tr('_', '-')} VALUE", type) { |v| options[key] = v }
  end
end.parse!
abort "duration/warmup must be positive; rounds must be positive and even" unless options[:duration].positive? && options[:warmup].positive? && options[:rounds].positive? && options[:rounds].even?
abort "workers must be nonnegative; threads, pool, warmup concurrency and client processes must be positive" unless options[:workers] >= 0 && [:threads, :db_pool, :warmup_concurrency, :client_processes].all? { |key| options[key].positive? }
abort "database pool must cover the request threads" if options[:db_pool] < options[:threads]
concurrencies = options[:concurrencies].split(",").map { |v| Integer(v) }
abort "concurrencies must be positive" unless concurrencies.all?(&:positive?) && !concurrencies.empty?
labels = JSON.parse(File.read(File.join(options[:seed], "labels.json")))
abort "Use an isolated benchmark seed" unless labels["fixture"] == "campfire-roda-benchmark-v1"
selected = options[:paths].split(",")
abort "Unknown or duplicate paths" unless (selected - %w[room messages sidebar search]).empty? && selected.uniq == selected && !selected.empty?
FileUtils.mkdir_p(options[:output])
root = File.expand_path("..", __dir__)
pid = nil
monitor = nil
samples = []
work = Dir.mktmpdir("campfire-http-")
begin
  unless options[:url]
    Campfire::Database.snapshot(File.join(options[:seed], "campfire.sqlite3"), File.join(work, "campfire.sqlite3"))
    port = TCPServer.open("127.0.0.1", 0) { |socket| socket.addr[1] }
    options[:url] = "http://127.0.0.1:#{port}"
    env = {"DATABASE_PATH" => File.join(work, "campfire.sqlite3"), "UPLOAD_ROOT" => File.expand_path(File.join(options[:seed], "files")), "RACK_ENV" => "production",
      "DISABLE_SSL" => "true", "SESSION_SECRET" => "isolated-benchmark-fixture-secret-" * 4,
      "HOST" => "127.0.0.1", "PORT" => port.to_s, "WEB_CONCURRENCY" => options[:workers].to_s,
      "MAX_THREADS" => options[:threads].to_s, "DB_POOL" => options[:db_pool].to_s}
    pid = Process.spawn(env, "bundle", "exec", "puma", "-C", "config/puma.rb", chdir: root,
      out: File.join(options[:output], "server.log"), err: [:child, :out])
  end
  endpoints = {"roda" => [options[:url], labels]}
  if options[:baseline_url]
    baseline = options[:baseline_labels] ? JSON.parse(File.read(options[:baseline_labels])) : labels
    endpoints["baseline"] = [options[:baseline_url], baseline]
  end
  clients = endpoints.to_h do |name, (url, fixture)|
    client = ParallelHTTPClient.new(url, processes: options[:client_processes])
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    until client.ready?
      raise "#{name} did not start; check #{options[:output]}/server.log" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end
    [name, [client, client.login(fixture), fixture]]
  end
  if pid
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    while File.read(File.join(options[:output], "server.log")).scan(/Worker \d+ \(PID: \d+\) booted/).length < options[:workers]
      raise "Puma workers did not boot" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end
    monitor = Thread.new do
      loop do
        sample = ProcessSampler.capture(roda: pid, client: Process.pid)
        samples << sample if sample
        sleep 1
      end
    end
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
        client.measure(path, cookie, concurrency: options[:warmup_concurrency], duration: options[:warmup])
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
  monitor&.kill
  monitor&.join
  File.write(File.join(options[:output], "resources.json"), JSON.pretty_generate({pids: {roda: pid, client: Process.pid}, samples: samples}) + "\n") if pid
  if pid
    Process.kill("TERM", pid) rescue Errno::ESRCH
    Process.wait(pid) rescue Errno::ECHILD
  end
  FileUtils.remove_entry(work)
end
