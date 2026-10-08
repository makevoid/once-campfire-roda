# frozen_string_literal: true

module Campfire
  # One background connection owns the lock for this database across all Puma
  # workers and delivery workers. PASSIVE never waits for readers to finish.
  class WalCheckpointer
    def initialize(path, interval: 0.25)
      @path, @interval = path, interval
      @mutex = Mutex.new
    end

    def start
      @mutex.synchronize do
        return if @thread&.alive?
        @wakeup = Queue.new
        @thread = Thread.new { run }
        @thread.name = "campfire-wal-checkpoint"
      end
    end

    def stop
      @mutex.synchronize do
        return unless @thread
        @wakeup.close
        begin
          @connection&.interrupt
        rescue SQLite3::Exception
          # The owner can close its handle between waking and this interrupt.
          # Joining still proves that the lock and connection were released.
        end
        raise "SQLite checkpointer did not stop before fork" unless @thread.join(5)
        @thread = nil
      end
    end

    private

    def run
      backoff = @interval
      until @wakeup.closed?
        lock = nil
        begin
          if File.file?(@path)
            lock = File.open("#{@path}.checkpoint.lock", File::RDWR | File::CREAT, 0o600)
            if lock.flock(File::LOCK_EX | File::LOCK_NB)
              @connection = SQLite3::Database.new(@path)
              @connection.busy_handler { |count| sleep(0.01); count < 100 }
              until @wakeup.closed?
                @connection.execute("PRAGMA wal_checkpoint(PASSIVE)")
                backoff = @interval
                @wakeup.pop(timeout: @interval)
              end
            end
          end
        rescue SQLite3::Exception, SystemCallError => error
          warn "SQLite checkpoint failed: #{error.class}" unless @wakeup.closed?
          backoff = [backoff * 2, 30].min
        ensure
          @connection&.close
          @connection = nil
          lock&.close
        end
        @wakeup.pop(timeout: backoff) unless @wakeup.closed?
      end
    end
  end
end
