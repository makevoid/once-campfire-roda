# frozen_string_literal: true

module Campfire
  module Realtime
    # One reader per process fans out committed events to bounded socket queues.
    # SQLite carries events across Puma workers; no Rails or Redis runtime is used.
    class Hub
      def initialize(db)
        @db, @mutex, @connections = db, Mutex.new, {}
      end

      def add
        @mutex.synchronize do
          if @connections.empty?
            @message_cursor = @db[:events].max(:id) || 0
            @broadcast_cursor = @db[:broadcasts].max(:id) || 0
          end
          queue = SizedQueue.new(256)
          @connections[queue] = true
          @thread = Thread.new { run } unless @thread&.alive?
          queue
        end
      end

      def remove(queue) = @mutex.synchronize { @connections.delete(queue) }

      def publish(stream, data)
        @db[:broadcasts].insert(stream: stream, payload: JSON.generate(data), created_at: Time.now.utc)
      end

      private

      def run
        loop do
          stop = @mutex.synchronize do
            if @connections.empty?
              @thread = nil
              true
            end
          end
          break if stop
          message_cursor, broadcast_cursor = @message_cursor, @broadcast_cursor
          messages = @db[:events].where { id > message_cursor }.order(:id).limit(128).all
          broadcasts = @db[:broadcasts].where { id > broadcast_cursor }.order(:id).limit(128).all
          @message_cursor = messages.last[:id] unless messages.empty?
          @broadcast_cursor = broadcasts.last[:id] unless broadcasts.empty?
          events = messages.map { |row| [:message, row] } + broadcasts.map { |row| [:broadcast, row] }
          @mutex.synchronize do
            @connections.each_key do |queue|
              events.each do |event|
                begin
                  queue.push(event, true)
                rescue ThreadError
                  queue.clear
                  queue.push([:overflow, nil], true)
                  break
                end
              end
            end
          end
          sleep 0.1
        end
      rescue StandardError => error
        warn "Realtime event reader stopped: #{error.class}"
        @mutex.synchronize { @connections.each_key { |queue| queue.clear; queue.push([:overflow, nil], true) }; @thread = nil }
      end
    end
  end
end
