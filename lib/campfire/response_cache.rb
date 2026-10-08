# frozen_string_literal: true

require "zlib"

module Campfire
  # A dedicated read-only connection observes commits by every SQLite writer.
  # data_version values must only be compared on that same connection. The
  # generation captured before authorization also gates admission after render.
  class ResponseCache
    MAX_ENTRY_BYTES = 1_048_576
    MAX_KEY_BYTES = 2048
    attr_reader :budget

    def initialize(db, megabytes: ENV.fetch("CAMPFIRE_RESPONSE_CACHE_MB", "64"))
      @db = db
      @path = db.opts[:database]
      @budget = [Integer(megabytes), 0].max * 1_048_576
      @mutex = Mutex.new
      @stripes = Array.new(16) { Mutex.new }
      @entries = {}
      @bytes = 0
      @generation = 0
    end

    def enabled? = budget.positive? && @path && @path != ":memory:"

    def version
      return unless enabled?
      @mutex.synchronize { current_version }
    rescue SQLite3::Exception, SystemCallError
      clear
      nil
    end

    def read(key, version)
      return unless version
      @mutex.synchronize { @entries[key]&.first if current_version == version }
    rescue SQLite3::Exception, SystemCallError
      clear
      nil
    end

    def write(key, version, entry)
      return unless version
      size = key.bytesize + entry[:body].bytesize + entry[:headers].sum { |k, v| k.bytesize + v.bytesize } + 256
      return if key.bytesize > MAX_KEY_BYTES || size > [budget, MAX_ENTRY_BYTES].min
      @mutex.synchronize do
        return unless current_version == version
        return if @entries.key?(key)
        while @entries.any? && @bytes + size > budget
          _, (_, removed) = @entries.shift
          @bytes -= removed
        end
        @entries[key.dup.freeze] = [entry, size]
        @bytes += size
      end
    rescue SQLite3::Exception, SystemCallError
      clear
    end

    def synchronize_render(key, version, &block)
      @stripes[[key, version].hash % @stripes.length].synchronize(&block)
    end

    # Request-local copies of immutable row snapshots share the response budget
    # and observer epoch. A hit still validates the database generation; expiry
    # and other time-based authorization checks remain the caller's job.
    def record(key, version)
      return yield unless version && enabled? && !@db.in_transaction?
      key = "record:#{key}"
      return yield if key.bytesize > MAX_KEY_BYTES
      if entry = read(key, version)
        return Marshal.load(entry[:body])
      end
      value = yield
      write(key, version, {body: Marshal.dump(value).freeze, headers: {}.freeze}.freeze) if value
      value
    end

    def clear
      @mutex.synchronize do
        @entries.clear
        @bytes = 0
        @observer&.close
        @observer = @version = nil
      end
    end

    private

    def current_version
      # Reopen after fork or replacement of the database file. Never compare
      # data_version from two different observers or inherit a live connection.
      stat = File.stat(@path)
      identity = [Process.pid, stat.dev, stat.ino]
      if !@observer || identity != @identity
        @observer&.close
        @observer = SQLite3::Database.new(@path, readonly: true)
        @identity = identity
        @version = nil
      end
      version = @observer.get_first_value("PRAGMA data_version")
      if @version != version
        @entries.clear
        @bytes = 0
        @generation += 1
        @version = version
      end
      @generation
    end
  end
end
