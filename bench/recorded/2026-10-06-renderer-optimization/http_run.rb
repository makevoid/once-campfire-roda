require 'bundler/setup'
require 'json'
require 'fileutils'
require 'socket'
require 'timeout'
require 'tmpdir'
require 'rbconfig'
require 'digest'
require_relative '../../lib/campfire/database'
require_relative '../../bench/http_client'
root = File.expand_path('../..', __dir__)
output = File.join(root, 'bench/results/optimization-http')
FileUtils.mkdir_p(output)
work = Dir.mktmpdir('campfire-optimization-')
children = []
labels_path = File.join(root, 'tmp/bench-seed/labels.json')
labels = JSON.parse(File.read(labels_path))
abort 'Not a benchmark fixture' unless labels['fixture'] == 'campfire-roda-benchmark-v1'
$stdout.sync = true
begin
  servers = {baseline: File.join(root, 'tmp/optimization-baseline'), roda: root}.to_h do |name, directory|
    database = File.join(work, "#{name}.sqlite3")
    Campfire::Database.snapshot(File.join(root, 'tmp/bench-seed/campfire.sqlite3'), database)
    port = TCPServer.open('127.0.0.1', 0) { |socket| socket.addr[1] }
    env = {'PATH' => "#{File.dirname(RbConfig.ruby)}:#{ENV.fetch('PATH')}", 'RUBYOPT' => '--yjit',
      'BUNDLE_PATH' => File.join(root, 'vendor/bundle'), 'BUNDLE_GEMFILE' => File.join(directory, 'Gemfile'), 'BUNDLE_FROZEN' => 'true',
      'DATABASE_PATH' => database, 'UPLOAD_ROOT' => File.join(root, 'tmp/bench-seed/files'),
      'RACK_ENV' => 'production', 'DISABLE_SSL' => 'true', 'SESSION_SECRET' => 'isolated-optimization-benchmark-secret-' * 3,
      'HOST' => '127.0.0.1', 'PORT' => port.to_s, 'WEB_CONCURRENCY' => '0', 'MAX_THREADS' => '5', 'DB_POOL' => '5'}
    children << Process.spawn(env, File.join(File.dirname(RbConfig.ruby), 'bundle'), 'exec', 'puma', '-C', 'config/puma.rb',
      chdir: directory, out: File.join(output, "#{name}.log"), err: [:child, :out])
    url = "http://127.0.0.1:#{port}"
    client = BenchmarkHTTPClient.new(url)
    Timeout.timeout(30) { sleep 0.1 until client.ready? }
    cookie = client.login(labels)
    ["/rooms/#{labels.fetch('rooms.watercooler')}", "/rooms/#{labels.fetch('rooms.watercooler')}/messages?before=#{labels.fetch('messages.busy_060')}", '/users/me/sidebar', '/searches?q=coffee'].each do |path|
      client.measure(path, cookie, concurrency: 1, duration: 3)
    end
    puts "Warmed #{name}"
    [name, url]
  end
  files = Dir.chdir(root) { Dir['app.rb', 'config.ru', 'Gemfile*', 'config/**/*', 'db/**/*', 'lib/**/*', 'views/**/*', 'public/**/*'].select { |path| File.file?(path) }.sort }
  digest = Digest::SHA256.new
  files.each { |path| digest << path << "\0" << File.binread(File.join(root, path)) << "\0" }
  File.write(File.join(output, 'metadata.json'), JSON.pretty_generate({before_commit: '34b0b1c518275e5b625cb331a9c3599a8d7198e3', after_runtime_sha256: digest.hexdigest, after_runtime_files: files, ruby: RUBY_DESCRIPTION, yjit: true, puma_threads: 5, puma_workers: 0, db_pool: 5, initial_prewarm_seconds: 3, description: 'Roda before and after renderer optimization, isolated copies of the same fixture, unchanged HTTP client, no response/fragment caching'}) + "\n")
  success = system({'RUBYOPT' => '--yjit'}, RbConfig.ruby, File.join(root, 'bench/compare_http.rb'),
    '--seed', File.join(root, 'tmp/bench-seed'), '--url', servers.fetch(:roda), '--baseline-url', servers.fetch(:baseline),
    '--duration', '5', '--warmup', '2', '--rounds', '4', '--concurrencies', '16', '--output', output)
  raise 'HTTP comparison failed' unless success
ensure
  children.reverse_each do |pid|
    Process.kill('TERM', pid) rescue Errno::ESRCH
    Process.wait(pid) rescue Errno::ECHILD
  end
  FileUtils.remove_entry(work)
end
