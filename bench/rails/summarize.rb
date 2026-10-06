# frozen_string_literal: true
require 'json'

def median(values)
  values = values.sort
  values.length.odd? ? values[values.length / 2] : (values[values.length / 2 - 1] + values[values.length / 2]) / 2.0
end

folder = ARGV.fetch(0)
sides = %w[baseline roda].to_h do |side|
  runs = Dir[File.join(folder, "#{side}-*.json")].sort.map { |path| JSON.parse(File.read(path)) }
  abort "Expected a positive even number of #{side} rounds" unless runs.length.positive? && runs.length.even?
  [side, runs]
end
abort 'Round counts differ' unless sides.values.map(&:length).uniq.length == 1
rows = sides.fetch('roda').first.fetch('results').keys.map do |key|
  row = {workload: key}
  sides.each do |side, runs|
    results = runs.map { |run| run.fetch('results').fetch(key) }
    raise "Errors in #{side} #{key}" unless results.all? { |r| r.fetch('errors') == 0 && r.fetch('statuses').keys == ['200'] }
    row[side] = {
      rps: median(results.map { |r| r.fetch('rps') }),
      rps_min: results.map { |r| r.fetch('rps') }.min,
      rps_max: results.map { |r| r.fetch('rps') }.max,
      p50_ms: median(results.map { |r| r.fetch('latency_ms').fetch('p50') }),
      p95_ms: median(results.map { |r| r.fetch('latency_ms').fetch('p95') }),
      p99_ms: median(results.map { |r| r.fetch('latency_ms').fetch('p99') }),
      avg_bytes: median(results.map { |r| r.fetch('avg_bytes') }),
      total_requests: results.sum { |r| r.fetch('ok') }
    }
  end
  row[:rps_ratio] = row.fetch('roda').fetch(:rps) / row.fetch('baseline').fetch(:rps)
  row
end
resources = JSON.parse(File.read(File.join(folder, 'resources.json')))
usage = resources.fetch('pids').to_h do |name, pid|
  samples = resources.fetch('samples').flat_map { |s| s.fetch('processes') }.select { |p| p.fetch('pid') == pid }
  [name, {max_cpu_percent: samples.map { |p| p.fetch('cpu_percent') }.max, max_rss_mib: samples.map { |p| p.fetch('rss_kib') / 1024.0 }.max}]
end
summary = {aggregation: "Median of #{sides.fetch('roda').length} per-round measurements; percentile medians are not pooled percentiles.", workloads: rows, resources: usage}
File.write(File.join(folder, 'summary.json'), JSON.pretty_generate(summary) + "\n")
rows.each do |row|
  rails, roda = row.values_at('baseline', 'roda')
  puts '| %s | %.0f | %.0f | %.2fx | %.2f / %.2f | %.2f / %.2f | %d / %d |' % [row[:workload], rails[:rps], roda[:rps], row[:rps_ratio], rails[:p50_ms], roda[:p50_ms], rails[:p95_ms], roda[:p95_ms], rails[:avg_bytes], roda[:avg_bytes]]
end
puts JSON.pretty_generate(usage)
puts "Total measured requests: #{rows.sum { |r| r['baseline'][:total_requests] + r['roda'][:total_requests] }}"
