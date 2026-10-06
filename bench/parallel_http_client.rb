# frozen_string_literal: true
require_relative "http_client"

# Keep the reference HTTP client unchanged. Multiple Ruby processes prevent its
# GVL from limiting a multi-worker server; retain raw samples for pooled p95/p99.
class ParallelHTTPClient < BenchmarkHTTPClient
  class Sampler < BenchmarkHTTPClient
    attr_reader :latencies

    private

    def percentile(values, fraction)
      @latencies = values
      super
    end
  end

  def initialize(base, processes: 1)
    super(base)
    raise ArgumentError, "processes must be positive" unless processes.positive?
    @base_url, @processes = base, processes
  end

  def measure(path, cookie, concurrency:, duration:)
    count = [@processes, concurrency].min
    return super if count == 1
    channels = Array.new(count) { {gate: IO.pipe, reply: IO.pipe} }
    pending = []
    count.times do |index|
      pending << fork do
        channels.each_with_index do |channel, other|
          channel[:gate][1].close
          channel[:reply][0].close
          channel[:gate][0].close unless index == other
          channel[:reply][1].close unless index == other
        end
        gate, reply = channels[index][:gate][0], channels[index][:reply][1]
        begin
          client = Sampler.new(@base_url)
          reply.write("R")
          reply.flush
          exit! 1 unless gate.read(1) == "G"
          share = concurrency / count + (index < concurrency % count ? 1 : 0)
          result = client.measure(path, cookie, concurrency: share, duration: duration)
          Marshal.dump({result: result, latencies: client.latencies}, reply)
          reply.close
          exit! 0
        rescue StandardError => error
          Marshal.dump({error: "#{error.class}: #{error.message}"}, reply)
          reply.close
          exit! 1
        ensure
          # Never unwind into the parent's process/pipe cleanup after a signal
          # or failed write in a child.
          exit! 1
        end
      end
    end
    channels.each { |channel| channel[:gate][0].close; channel[:reply][1].close }
    channels.each { |channel| raise "Load generator failed to start" unless channel[:reply][0].read(1) == "R" }
    started = clock
    channels.each { |channel| channel[:gate][1].write("G"); channel[:gate][1].close }
    samples = channels.map { |channel| Marshal.load(channel[:reply][0]) }
    elapsed = clock - started
    raise samples.filter_map { |sample| sample[:error] }.join("; ") if samples.any? { |sample| sample[:error] }
    until pending.empty?
      _, status = Process.wait2(pending.first)
      pending.shift
      raise "Load generator exited unsuccessfully" unless status.success?
    end
    results = samples.map { |sample| sample.fetch(:result) }
    latencies = samples.flat_map { |sample| sample.fetch(:latencies) }.sort
    statuses = Hash.new(0)
    results.each { |result| result[:statuses].each { |status, total| statuses[status] += total } }
    {path: path, conc: concurrency, client_processes: count, gzip: false, secs: elapsed, rps: latencies.length / elapsed,
      ok: latencies.length, statuses: statuses, errors: results.sum { |result| result[:errors] },
      avg_bytes: results.sum { |result| result[:avg_bytes] * result[:ok] } / latencies.length,
      latency_ms: {p50: percentile(latencies, 0.50), p95: percentile(latencies, 0.95), p99: percentile(latencies, 0.99)}}
  ensure
    channels&.each { |channel| channel.values.flatten.each { |io| io.close unless io.closed? } }
    pending&.each do |pid|
      Process.kill("TERM", pid) rescue Errno::ESRCH
      Process.wait(pid) rescue Errno::ECHILD
    end
  end
end
