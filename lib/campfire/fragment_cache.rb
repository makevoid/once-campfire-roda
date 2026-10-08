# frozen_string_literal: true

module Campfire
  # Only content-addressed renderer output goes here. Unlike page snapshots,
  # these entries can survive unrelated commits because keys describe every
  # input to the fragment, including values changed by foreign SQL writers.
  class FragmentCache
    def initialize(megabytes: ENV.fetch("CAMPFIRE_FRAGMENT_CACHE_MB", "64"))
      @budget = [Integer(megabytes), 0].max * 1_048_576
      @mutex, @entries, @bytes = Mutex.new, {}, 0
    end

    def enabled? = @budget.positive?

    def fetch(key)
      return yield unless enabled?
      if entry = @mutex.synchronize { @entries[key] }
        return entry.first
      end
      body = yield
      size = key.bytesize + body.bytesize + 128
      return body if size > [@budget, ResponseCache::MAX_ENTRY_BYTES].min
      @mutex.synchronize do
        return @entries[key].first if @entries.key?(key)
        while @entries.any? && @bytes + size > @budget
          _, (_, removed) = @entries.shift
          @bytes -= removed
        end
        @entries[key.freeze] = [body.freeze, size]
        @bytes += size
      end
      body
    end
  end
end
