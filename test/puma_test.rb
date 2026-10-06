# frozen_string_literal: true
require_relative "test_helper"
require "puma"
require "puma/configuration"
require "puma/server"
require_relative "../bench/parallel_http_client"
require_relative "../bench/process_sampler"

class PumaTest < Minitest::Test
  def test_preloaded_database_is_disconnected_before_workers_fork
    Dir.mktmpdir("campfire-fork-") do |directory|
      database = Campfire::Database.connect(path: File.join(directory, "data.sqlite3"), pool: 2)
      database.create_table(:worker_writes) { Integer :worker }
      config = cluster_config
      assert_equal 2, config.options[:workers]
      assert config.options[:preload_app]
      config.options.fetch(:before_fork).each { |hook| hook.fetch(:block).call }
      assert_equal 0, database.pool.size
      children = 2.times.map do
        fork do
          10.times { database[:worker_writes].insert(worker: Process.pid) }
          database.disconnect
          exit! 0
        rescue StandardError
          exit! 1
        end
      end
      children.each { |pid| assert Process.wait2(pid).last.success? }
      assert_equal 20, database[:worker_writes].count
      assert_equal 2, database[:worker_writes].select(:worker).distinct.count
    ensure
      database&.disconnect
    end
  end

  def test_parallel_client_combines_all_requests_and_propagates_http_failures
    application = ->(env) { [env["PATH_INFO"] == "/fail" ? 500 : 200, {"content-type" => "text/plain"}, ["ok"]] }
    server = Puma::Server.new(application)
    server.add_tcp_listener("127.0.0.1", 0)
    port = server.binder.ios.first.addr[1]
    server.run
    client = ParallelHTTPClient.new("http://127.0.0.1:#{port}", processes: 2)
    result = client.measure("/", "fixture=1", concurrency: 5, duration: 0.1)
    assert_equal 5, result[:conc]
    assert_equal 2, result[:client_processes]
    assert_equal({"200" => result[:ok]}, result[:statuses])
    assert_equal 0, result[:errors]
    assert_equal 2, result[:avg_bytes]
    assert_operator result[:ok], :>, 0
    assert_operator result[:secs], :>=, 0.1
    assert_equal result[:ok] / result[:secs], result[:rps]
    assert_operator result[:latency_ms][:p99], :>=, result[:latency_ms][:p95]
    assert_operator result[:latency_ms][:p95], :>=, result[:latency_ms][:p50]
    error = assert_raises(RuntimeError) { client.measure("/fail", "fixture=1", concurrency: 2, duration: 0.05) }
    assert_includes error.message, "500"
  ensure
    server&.stop(true)
  end

  def test_process_resource_groups_do_not_count_a_child_server_twice
    reader, writer = IO.pipe
    child = fork do
      writer.close
      reader.read
      exit! 0
    end
    reader.close
    sample = ProcessSampler.capture(client: Process.pid, server: child)
    assert_includes sample[:groups][:server][:pids], child
    refute_includes sample[:groups][:client][:pids], child
    ids = sample[:processes].map { |row| row[:pid] }
    assert_equal ids.uniq, ids
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
    Process.wait(child) if child
  end

  private

  def cluster_config
    values = {"WEB_CONCURRENCY" => "2", "MAX_THREADS" => "2", "RACK_ENV" => "production"}
    previous = values.to_h { |key, _| [key, ENV[key]] }
    ENV.update(values)
    configuration = Puma::Configuration.new(config_files: [File.expand_path("../config/puma.rb", __dir__)])
    configuration.load
    configuration.clamp
    configuration
  ensure
    previous.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end
end
