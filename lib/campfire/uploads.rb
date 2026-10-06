# frozen_string_literal: true

module Campfire
  class Uploads
    MAX_SIZE = 25 * 1024 * 1024
    IMAGE_TYPES = %w[image/png image/jpeg image/gif image/webp].freeze
    attr_reader :root
    def initialize(root)
      @root = File.expand_path(root)
      FileUtils.mkdir_p(@root)
    end

    def stage(upload)
      return if upload.nil? || upload == ""
      raise Error, "Invalid upload" unless upload.is_a?(Hash) && upload[:tempfile].respond_to?(:size)
      file = upload[:tempfile]
      raise Error, "Files must be no larger than 25 MB" if file.size > MAX_SIZE
      name = File.basename(upload[:filename].to_s.tr("\\", "/")).gsub(/[\x00-\x1f\x7f]/, "")[0, 200]
      raise Error, "File needs a name" if name.empty?
      key = SecureRandom.hex(32)
      FileUtils.copy_file(file.path, path(key))
      {key: key, filename: name, byte_size: file.size, content_type: content_type(path(key), name)}
    end

    def image_type(path)
      header = File.binread(path, 12)
      return "image/png" if header.start_with?("\x89PNG\r\n\x1a\n".b)
      return "image/jpeg" if header.start_with?("\xff\xd8\xff".b)
      return "image/gif" if header.start_with?("GIF87a", "GIF89a")
      return "image/webp" if header.start_with?("RIFF") && header[8, 4] == "WEBP"
      nil
    end

    def content_type(path, filename)
      type = image_type(path)
      return type if type
      header = File.binread(path, 64)
      return "application/pdf" if header.start_with?("%PDF-")
      if header[4, 4] == "ftyp"
        return File.extname(filename).downcase == ".m4a" ? "audio/mp4" : "video/mp4"
      end
      return "video/webm" if header.start_with?("\x1a\x45\xdf\xa3".b)
      return "audio/mpeg" if header.start_with?("ID3") || header.start_with?("\xff\xfb".b)
      return "audio/ogg" if header.start_with?("OggS")
      return "audio/wav" if header.start_with?("RIFF") && header[8, 4] == "WAVE"
      "application/octet-stream"
    end

    def path(key)
      raise Error.new("File not found", 404) unless key.match?(/\A[0-9a-f]{64}\z/)
      File.join(root, key)
    end

    def discard(upload)
      FileUtils.rm_f(path(upload[:key])) if upload
    end
  end
end
