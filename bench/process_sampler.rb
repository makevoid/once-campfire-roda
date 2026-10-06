# frozen_string_literal: true
require "open3"
require "time"

# Attribute all descendants to their server, rather than measuring only the
# almost-idle Puma master in cluster mode. Keep unrelated process data private.
module ProcessSampler
  def self.capture(roots)
    output, status, sampler_pid = Open3.popen2("ps", "-axo", "pid=,ppid=,pcpu=,rss=") do |input, result, waiter|
      input.close
      [result.read, waiter.value, waiter.pid]
    end
    return unless status.success?
    rows = output.lines.map do |line|
      pid, parent, cpu, rss = line.split
      {pid: pid.to_i, parent_pid: parent.to_i, cpu_percent: cpu.to_f, rss_kib: rss.to_i}
    end.reject { |row| row[:pid] == sampler_pid }
    processes = []
    groups = roots.to_h do |name, root|
      ids = [root]
      loop do
        children = rows.select { |row| ids.include?(row[:parent_pid]) && !roots.value?(row[:pid]) }.map { |row| row[:pid] }
        expanded = (ids + children).uniq
        break if expanded == ids
        ids = expanded
      end
      members = rows.select { |row| ids.include?(row[:pid]) }
      processes.concat(members.map { |row| row.merge(group: name) })
      [name, {pids: members.map { |row| row[:pid] }, cpu_percent: members.sum { |row| row[:cpu_percent] }, rss_kib: members.sum { |row| row[:rss_kib] }}]
    end
    {at: Time.now.utc.iso8601, groups: groups, processes: processes}
  end
end
