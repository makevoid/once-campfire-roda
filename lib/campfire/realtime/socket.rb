# frozen_string_literal: true

require "websocket/driver"
require "io/wait"

module Campfire
  module Realtime
    class Socket
      attr_reader :env, :url

      def initialize(container, request, token, csrf)
        @container, @env = container, request.env
        @url = "#{request.ssl? ? 'wss' : 'ws'}://#{request.host_with_port}#{request.fullpath}"
        @driver = WebSocket::Driver.rack(self, protocols: ["actioncable-v1-json"], max_length: 16_384)
        @protocol = Protocol.new(container: container, token: token, request: request, csrf: csrf,
          emit: ->(packet) { @driver.text(packet) }, close: -> { @driver.close })
        @driver.on(:open) { @protocol.start }
        @driver.on(:message) { |event| @protocol.receive(event.data) }
        @driver.on(:close) { @closed = true }
        @driver.on(:error) { @closed = true }
        @env.fetch("rack.hijack").call
        @io = @env.fetch("rack.hijack_io")
        @queue = container.hub.add
        Thread.new { run }
      end

      def write(bytes)
        offset = 0
        while offset < bytes.bytesize
          raise IOError, "Slow WebSocket reader" unless @io.wait_writable(5)
          count = @io.write_nonblock(bytes.byteslice(offset..), exception: false)
          offset += count if count.is_a?(Integer)
        end
        bytes.bytesize
      end

      private

      def run
        @driver.start
        next_ping = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
        until @closed || @protocol.closed
          if @io.wait_readable(0.05)
            bytes = @io.read_nonblock(65_536, exception: false)
            break if bytes.nil?
            @driver.parse(bytes) if bytes.is_a?(String)
          end
          128.times do
            event = @queue.pop(true) rescue ThreadError
            break unless event.is_a?(Array)
            @protocol.deliver(*event)
          end
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if now >= next_ping
            @protocol.tick
            next_ping = now + 3
          end
        end
      rescue IOError, SystemCallError
        # A closed or stalled client must not retain presence or a queue.
      rescue StandardError => error
        warn "WebSocket closed: #{error.class}: #{error.message}"
      ensure
        @protocol.cleanup
        @container.hub.remove(@queue)
        @io.close unless @io.closed?
      end
    end
  end
end
