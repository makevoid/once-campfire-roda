# frozen_string_literal: true

require "vips"
require "zlib"
require "open3"
require "timeout"
require "tmpdir"

module Campfire
  class Media
    Vips.block_untrusted(true)
    Vips.block("VipsForeignLoadOpenslide", true)
    AVATAR_COLORS = %w[#AF2E1B #CC6324 #3B4B59 #BFA07A #ED8008 #ED3F1C #BF1B1B #736B1E #D07B53
      #736356 #AD1D1D #BF7C2A #C09C6F #698F9C #7C956B #5D618F #3B3633 #67695E].freeze
    VARIANTS = {avatar: [512, 512, "webp"], logo: [512, 512, "png"], small_logo: [192, 192, "png"], thumb: [1200, 800, "webp"]}.freeze
    THUMBNAIL_MAX_PIXELS = 250_000_000

    def initialize(db, uploads)
      @db, @uploads = db, uploads
    end

    def find(owner_type, owner_id, purpose)
      @db[:media][owner_type: owner_type, owner_id: owner_id, purpose: purpose]
    end

    def replace(owner_type, owner_id, purpose, upload)
      staged = @uploads.stage(upload)
      return unless staged
      metadata = image_metadata(staged)
      @db.transaction(mode: :immediate) do
        @db[:media].where(owner_type: owner_type, owner_id: owner_id, purpose: purpose).delete
        @db[:media].insert(staged.merge(owner_type: owner_type, owner_id: owner_id, purpose: purpose,
          metadata: JSON.generate(metadata), created_at: Time.now.utc))
        @db[owner_type == "User" ? :users : :accounts].where(id: owner_id).update(updated_at: Time.now.utc)
      end
    rescue StandardError
      @uploads.discard(staged)
      raise
    end

    def remove(owner_type, owner_id, purpose)
      @db.transaction(mode: :immediate) do
        @db[:media].where(owner_type: owner_type, owner_id: owner_id, purpose: purpose).delete
        @db[owner_type == "User" ? :users : :accounts].where(id: owner_id).update(updated_at: Time.now.utc)
      end
    end

    def image_metadata(file)
      return {} unless Uploads::IMAGE_TYPES.include?(file[:content_type])
      image = Vips::Image.new_from_file(@uploads.path(file[:key]), access: :sequential)
      {width: image.width, height: image.height}
    rescue Vips::Error
      raise Error, "Image cannot be decoded"
    end

    def analyze_attachment(file)
      if Uploads::IMAGE_TYPES.include?(file[:content_type])
        image_metadata(file)
      elsif file[:content_type].start_with?("video/", "audio/")
        data = JSON.parse(command("ffprobe", "-v", "error", "-protocol_whitelist", "file,pipe", "-show_streams", "-show_format", "-of", "json", @uploads.path(file[:key])))
        video = data.fetch("streams", []).find { |entry| entry["codec_type"] == "video" } || {}
        {width: video["width"], height: video["height"], duration: data.dig("format", "duration")&.to_f}.compact
      else
        {}
      end
    rescue Error, JSON::ParserError
      {}
    end

    def variant(file, name)
      return unless file
      return unless name != :thumb || preview_dimensions_allowed?(file)
      return preview(file) if name == :thumb && (file[:content_type].start_with?("video/") || file[:content_type] == "application/pdf")
      return unless Uploads::IMAGE_TYPES.include?(file[:content_type])
      width, height, format = VARIANTS.fetch(name)
      key = Digest::SHA256.hexdigest("variant-v1:#{file[:key]}:#{name}")
      path = @uploads.path(key)
      unless File.exist?(path)
        image = Vips::Image.thumbnail(@uploads.path(file[:key]), width, height: height, size: :down)
        bytes = image.write_to_buffer(".#{format}")
        temporary = "#{path}.#{SecureRandom.hex(8)}.tmp"
        begin
          File.binwrite(temporary, bytes)
          File.rename(temporary, path)
        ensure
          FileUtils.rm_f(temporary)
        end
      end
      [path, "image/#{format}"]
    rescue Vips::Error
      nil
    end

    # Attachment views only serve already generated previews. Unsupported or
    # failed uploads remain downloadable without retrying expensive work per view.
    def existing_variant(file, name)
      return unless file
      preview = name == :thumb && (file[:content_type].start_with?("video/") || file[:content_type] == "application/pdf")
      format = preview ? "webp" : VARIANTS.fetch(name).last
      key = Digest::SHA256.hexdigest(preview ? "preview-v1:#{file[:key]}" : "variant-v1:#{file[:key]}:#{name}")
      path = @uploads.path(key)
      [path, "image/#{format}"] if File.file?(path)
    end

    def preview_dimensions_allowed?(file)
      return true unless Uploads::IMAGE_TYPES.include?(file[:content_type]) || file[:content_type].start_with?("video/")
      metadata = JSON.parse(file[:metadata] || "{}")
      width, height = metadata.values_at("width", "height")
      width.is_a?(Numeric) && height.is_a?(Numeric) && width.positive? && height.positive? && width * height <= THUMBNAIL_MAX_PIXELS
    end

    def preview(file)
      return unless preview_dimensions_allowed?(file)
      key = Digest::SHA256.hexdigest("preview-v1:#{file[:key]}")
      target = @uploads.path(key)
      unless File.exist?(target)
        Dir.mktmpdir("campfire-preview-") do |directory|
          source = @uploads.path(file[:key])
          intermediate = File.join(directory, "preview.png")
          if file[:content_type] == "application/pdf"
            command("pdftoppm", "-f", "1", "-l", "1", "-singlefile", "-scale-to", "1200", "-png", source, File.join(directory, "preview"))
          else
            command("ffmpeg", "-nostdin", "-v", "error", "-protocol_whitelist", "file,pipe", "-i", source, "-frames:v", "1", "-vf", "scale=1200:800:force_original_aspect_ratio=decrease", intermediate)
          end
          image = Vips::Image.thumbnail(intermediate, 1200, height: 800, size: :down)
          path = File.join(directory, "preview.webp")
          image.write_to_file(path)
          temporary = "#{target}.#{SecureRandom.hex(8)}.tmp"
          begin
            FileUtils.cp(path, temporary)
            File.rename(temporary, target)
          ensure
            FileUtils.rm_f(temporary)
          end
        end
      end
      [target, "image/webp"]
    rescue Error, Vips::Error
      nil
    end

    def command(*arguments)
      output = +""
      Open3.popen3(*arguments, pgroup: true) do |input, out, err, process|
        input.close
        error_reader = Thread.new { nil while err.read(4096) }
        begin
          Timeout.timeout(10) do
            output = out.read(1_048_576)
            raise Error, "Media processor failed" unless process.value.success?
          end
        rescue Timeout::Error
          Process.kill("KILL", -process.pid) rescue Errno::ESRCH
          raise Error, "Media processing timed out"
        ensure
          error_reader.join
        end
      end
      output
    rescue Errno::ENOENT
      raise Error, "Media processor is unavailable"
    end

    def initials_svg(user)
      initials = user[:name].to_s.scan(/\b\w/).join
      color = AVATAR_COLORS[Zlib.crc32(user.id.to_s) % AVATAR_COLORS.length]
      spacing = initials.length >= 3 ? 'textLength="85%" lengthAdjust="spacingAndGlyphs"' : ""
      %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" class="avatar" aria-hidden="true"><rect width="100%" height="100%" rx="50" fill="#{color}"/><text x="50%" y="50%" fill="#FFFFFF" text-anchor="middle" dy="0.35em" #{spacing} font-family="-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif" font-size="230" font-weight="800" letter-spacing="-5">#{CGI.escapeHTML(initials)}</text></svg>)
    end
  end
end
