# frozen_string_literal: true
require "fileutils"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "timeout"
require "time"
require "digest"
require_relative "../http_client"

ROOT = File.expand_path("../..", __dir__)
SOURCE = File.expand_path(ENV.fetch("RAILS_SOURCE", "tmp/once-campfire"), ROOT)
abort "Rails source has tracked changes; use a clean checkout" unless Open3.capture2("git", "-C", SOURCE, "status", "--porcelain", "--untracked-files=no").first.empty?
RUBY = RbConfig.ruby
BUNDLE = File.join(File.dirname(RUBY), "bundle")
stamp = Time.now.utc.strftime("%Y%m%d-%H%M%S")
work = File.join(ROOT, "tmp/rails-comparison", stamp)
runtime = File.join(work, "rails")
output = File.join(ROOT, "bench/results", "rails-vs-roda-#{stamp}")
abort "Run directory already exists" if File.exist?(work) || File.exist?(output)
FileUtils.mkdir_p([runtime, output])
puts "Results: #{output}"
$stdout.sync = true
%w[app bin config db lib public Gemfile Gemfile.lock Rakefile config.ru].each do |entry|
  FileUtils.cp_r(File.join(SOURCE, entry), runtime)
end
FileUtils.mkdir_p(File.join(runtime, "vendor"))
FileUtils.cp_r(File.join(SOURCE, "vendor/javascript"), File.join(runtime, "vendor/javascript"))
FileUtils.mkdir_p([File.join(runtime, "storage/db"), File.join(runtime, "storage/files"), File.join(runtime, "tmp/pids"), File.join(runtime, "log")])
# The source initializer calls Vips.block_untrusted without loading ruby-vips first.
# Load the installed library; retain all of the source's operation restrictions.
File.write(File.join(runtime, "config/initializers/00_load_vips.rb"), "require 'vips'\n")
File.write(File.join(runtime, "config/puma.benchmark.rb"), <<~CONFIG)
  require_relative "environment"
  threads 5, 5
  workers 0
  bind "tcp://127.0.0.1:\#{ENV.fetch('PORT')}"
  environment "production"
  Membership.disconnect_all
  puts "BENCH_RUNTIME Rails=\#{Rails.version} Ruby=\#{RUBY_VERSION} YJIT=\#{RubyVM::YJIT.enabled?} Puma=\#{Puma::Const::PUMA_VERSION}"
CONFIG

common = {"PATH" => "#{File.dirname(RUBY)}:#{ENV.fetch('PATH')}", "RUBYOPT" => "--yjit", "BUNDLE_FROZEN" => "true"}
rails_env = common.merge("BUNDLE_PATH" => File.join(SOURCE, "vendor/bundle"), "BUNDLE_GEMFILE" => File.join(runtime, "Gemfile"),
  "BUNDLE_WITHOUT" => "development:test", "RAILS_ENV" => "production", "DISABLE_SSL" => "true", "SKIP_TELEMETRY" => "true",
  "SECRET_KEY_BASE" => "isolated-benchmark-fixture-key-" * 4, "RAILS_LOG_LEVEL" => "error", "WEB_CONCURRENCY" => "0", "RAILS_MAX_THREADS" => "5")
roda_env = common.merge("BUNDLE_PATH" => File.join(ROOT, "vendor/bundle"), "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"), "BUNDLE_WITHOUT" => "")

def run!(env, directory, log, *command)
  success = system(env, *command, chdir: directory, out: log, err: [:child, :out])
  raise "Command failed: #{command.join(' ')}; see #{log}" unless success
end

def unused_port
  TCPServer.open("127.0.0.1", 0) { |socket| socket.addr[1] }
end

seed_source = File.expand_path(ENV.fetch("BENCH_SEED", "tmp/bench-seed"), ROOT)
abort "Use a disposable benchmark seed" unless JSON.parse(File.read(File.join(seed_source, "labels.json")))["fixture"] == "campfire-roda-benchmark-v1"
database = File.join(runtime, "storage/db/production.sqlite3")
run!(rails_env, runtime, File.join(output, "seed.log"), BUNDLE, "exec", RUBY, File.join(__dir__, "seed.rb"),
  File.join(runtime, "db/schema.rb"), File.join(seed_source, "campfire.sqlite3"), database)
puts "Prepared Rails fixture"
labels = File.join(work, "labels.json")
FileUtils.cp(File.join(seed_source, "labels.json"), labels)
matching = File.join(work, "matching-roda")
run!(roda_env, ROOT, File.join(output, "import.log"), BUNDLE, "exec", RUBY, "bench/import_rails_seed.rb",
  "--database", database, "--labels", labels, "--storage", File.join(runtime, "storage/files"), "--output", matching)
puts "Imported matching Roda fixture"
run!(rails_env, runtime, File.join(output, "assets.log"), BUNDLE, "exec", RUBY, "bin/rails", "assets:precompile")
puts "Compiled Rails assets"

children = []
begin
  redis_port = unused_port
  redis_dir = File.join(work, "redis")
  FileUtils.mkdir_p(redis_dir)
  redis_pid = Process.spawn(ENV.fetch("REDIS_SERVER", "redis-server"), "--bind", "127.0.0.1", "--port", redis_port.to_s,
    "--save", "", "--appendonly", "no", "--dir", redis_dir, out: File.join(output, "redis.log"), err: [:child, :out])
  children << redis_pid
  Timeout.timeout(10) do
    loop do
      begin
        Socket.tcp("127.0.0.1", redis_port, connect_timeout: 0.5) do |socket|
          socket.write("*1\r\n$4\r\nPING\r\n")
          raise "Redis did not reply" unless socket.gets == "+PONG\r\n"
        end
        break
      rescue Errno::ECONNREFUSED
        sleep 0.1
      end
    end
  end
  port = unused_port
  rails_env.merge!("REDIS_URL" => "redis://127.0.0.1:#{redis_port}/0", "PORT" => port.to_s)
  rails_pid = Process.spawn(rails_env, BUNDLE, "exec", "puma", "-C", "config/puma.benchmark.rb", chdir: runtime,
    out: File.join(output, "rails.log"), err: [:child, :out])
  children << rails_pid
  client = BenchmarkHTTPClient.new("http://127.0.0.1:#{port}")
  Timeout.timeout(45) { sleep 0.1 until client.ready? }
  puts "Rails and isolated Redis are ready"
  roda_port = unused_port
  roda_server_env = roda_env.merge("DATABASE_PATH" => File.join(matching, "campfire.sqlite3"), "UPLOAD_ROOT" => File.join(matching, "files"),
    "RACK_ENV" => "production", "DISABLE_SSL" => "true", "SESSION_SECRET" => "isolated-benchmark-fixture-secret-" * 4,
    "HOST" => "127.0.0.1", "PORT" => roda_port.to_s, "WEB_CONCURRENCY" => "0", "MAX_THREADS" => "5", "DB_POOL" => "5")
  roda_pid = Process.spawn(roda_server_env, BUNDLE, "exec", "puma", "-C", "config/puma.rb", chdir: ROOT,
    out: File.join(output, "server.log"), err: [:child, :out])
  children << roda_pid
  roda_client = BenchmarkHTTPClient.new("http://127.0.0.1:#{roda_port}")
  Timeout.timeout(30) { sleep 0.1 until roda_client.ready? }
  run!(roda_env, ROOT, File.join(output, "verification.log"), BUNDLE, "exec", RUBY, File.join(__dir__, "verify.rb"),
    File.join(seed_source, "campfire.sqlite3"), File.join(matching, "campfire.sqlite3"), labels,
    "http://127.0.0.1:#{port}", "http://127.0.0.1:#{roda_port}", File.join(output, "verification.json"))
  puts "Verified matching fixture records and message IDs from both HTTP servers"
  hardware = if RUBY_PLATFORM.include?("darwin")
    {cpu: Open3.capture2("sysctl", "-n", "machdep.cpu.brand_string").first.strip,
      physical_cpus: Open3.capture2("sysctl", "-n", "hw.physicalcpu").first.strip.to_i,
      memory_bytes: Open3.capture2("sysctl", "-n", "hw.memsize").first.strip.to_i}
  else
    {platform: RUBY_PLATFORM, note: "Record CPU and memory separately on this platform."}
  end
  runtime_files = Dir.chdir(ROOT) { Dir["app.rb", "config.ru", "Gemfile*", "config/**/*", "db/**/*", "lib/**/*", "views/**/*", "public/**/*"].select { |path| File.file?(path) }.sort }
  runtime_digest = Digest::SHA256.new
  runtime_files.each { |path| runtime_digest << path << "\0" << File.binread(File.join(ROOT, path)) << "\0" }
  metadata = {orchestrator_ruby: RUBY_DESCRIPTION, yjit: true, puma_threads: 5, puma_workers: 0, hardware: hardware,
    roda_runtime_sha256: runtime_digest.hexdigest, roda_runtime_files: runtime_files,
    rails_source: SOURCE, rails_ref: Open3.capture2("git", "-C", SOURCE, "rev-parse", "HEAD").first.strip,
    fixture: JSON.parse(File.read(labels)), runtime: runtime, output: output,
    note: "Loopback only. Both apps use the same Ruby with YJIT; Rails keeps production Redis caching. No CPU affinity on macOS. Vips preloaded to fix source initializer load order."}
  File.write(File.join(output, "metadata.json"), JSON.pretty_generate(metadata) + "\n")
  if ENV["BENCH_PARITY"] == "1"
    run!(roda_env, ROOT, File.join(output, "parity.log"), BUNDLE, "exec", RUBY, "bench/verify_parity.rb",
      "--rails-url", "http://127.0.0.1:#{port}", "--roda-url", "http://127.0.0.1:#{roda_port}",
      "--rails-database", database, "--roda-database", File.join(matching, "campfire.sqlite3"),
      "--labels", labels, "--output", File.join(output, "parity.json"))
    puts File.read(File.join(output, "parity.log"))
    exit
  end
  fixture = JSON.parse(File.read(labels))
  [client, roda_client].each do |warm_client|
    cookie = warm_client.login(fixture)
    ["/rooms/#{fixture.fetch('rooms.watercooler')}", "/rooms/#{fixture.fetch('rooms.watercooler')}/messages?before=#{fixture.fetch('messages.busy_060')}",
      "/users/me/sidebar", "/searches?q=coffee"].each do |path|
      warm_client.measure(path, cookie, concurrency: 1, duration: Float(ENV.fetch("BENCH_PREWARM", "5")))
    end
  end
  puts "Finished initial JIT/cache warmup"
  duration = ENV.fetch("BENCH_DURATION", "5")
  warmup = ENV.fetch("BENCH_WARMUP", "3")
  rounds = ENV.fetch("BENCH_ROUNDS", "4")
  comparison_pid = Process.spawn(roda_env, BUNDLE, "exec", RUBY, "bench/compare_http.rb", "--seed", matching,
    "--url", "http://127.0.0.1:#{roda_port}",
    "--baseline-url", "http://127.0.0.1:#{port}", "--baseline-labels", labels,
    "--duration", duration, "--warmup", warmup, "--rounds", rounds, "--output", output, chdir: ROOT)
  children << comparison_pid
  samples = []
  monitor = Thread.new do
    loop do
      text, status = Open3.capture2("ps", "-p", [rails_pid, roda_pid, redis_pid, comparison_pid].join(","), "-o", "pid=,pcpu=,rss=")
      samples << {at: Time.now.utc.iso8601, processes: text.lines.map { |line| pid, cpu, rss = line.split; {pid: pid.to_i, cpu_percent: cpu.to_f, rss_kib: rss.to_i} }} if status.success?
      sleep 1
    end
  end
  _, status = Process.wait2(comparison_pid)
  children.delete(comparison_pid)
  monitor.kill
  monitor.join
  File.write(File.join(output, "resources.json"), JSON.pretty_generate({pids: {rails: rails_pid, roda: roda_pid, redis: redis_pid, client: comparison_pid}, samples: samples}) + "\n")
  raise "HTTP comparison failed; see #{output}" unless status.success?
  puts "Completed comparison: #{output}"
ensure
  monitor&.kill
  children.reverse_each do |pid|
    begin
      Process.kill("TERM", pid)
      Timeout.timeout(10) { Process.wait(pid) }
    rescue Errno::ESRCH, Errno::ECHILD
    rescue Timeout::Error
      Process.kill("KILL", pid) rescue Errno::ESRCH
      Process.wait(pid) rescue Errno::ECHILD
    end
  end
end
