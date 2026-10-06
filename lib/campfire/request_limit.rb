# frozen_string_literal: true
module Campfire
  class RequestLimit
    class TooLarge < Error
      def initialize = super("Request too large", 413)
    end
    MAX_BYTES = Uploads::MAX_SIZE + 1_048_576

    class Input
      def initialize(io)
        @io, @read = io, 0
      end

      def read(length = nil, buffer = nil)
        max = MAX_BYTES - @read + 1
        data = @io.read(length ? [length, max].min : max)
        data = "" if data.nil? && length.nil?
        @read += data.to_s.bytesize
        raise TooLarge if @read > MAX_BYTES
        buffer.replace(data || "") if buffer
        data && (buffer || data)
      end

      def gets
        line = @io.gets(MAX_BYTES - @read + 1)
        @read += line.to_s.bytesize
        raise TooLarge if @read > MAX_BYTES
        line
      end

      def each
        while (line = gets)
          yield line
        end
      end

      def rewind
        @read = 0
        @io.rewind
      end
    end

    def initialize(app) = @app = app
    def call(env)
      raise TooLarge if env["CONTENT_LENGTH"].to_i > MAX_BYTES
      env["rack.input"] = Input.new(env["rack.input"]) if env["rack.input"]
      @app.call(env)
    rescue TooLarge
      [413, {"content-type" => "text/plain; charset=utf-8", "content-length" => "17"}, ["Request too large"]]
    end
  end
end
