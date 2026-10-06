# frozen_string_literal: true

module Campfire
  # Streams a whole file or a single HTTP byte range without loading the file.
  class FileBody
    def initialize(path, offset: 0, length: File.size(path))
      @path, @offset, @length = path, offset, length
    end

    def each
      File.open(@path, "rb") do |file|
        file.seek(@offset)
        remaining = @length
        while remaining.positive? && (chunk = file.read([remaining, 64 * 1024].min))
          yield chunk
          remaining -= chunk.bytesize
        end
      end
    end
  end
end
