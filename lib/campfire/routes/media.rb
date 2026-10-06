# frozen_string_literal: true

require "rqrcode"

module Campfire
  module Routes
    module Media
      private

      def send_local_file(path, content_type, cache: "private, no-cache")
        raise Error.new("File not found", 404) unless File.file?(path)
        etag = %Q{"#{Digest::SHA256.file(path).hexdigest}"}
        response["etag"] = etag
        response["cache-control"] = cache
        request.halt 304 if request.env["HTTP_IF_NONE_MATCH"] == etag
        size = File.size(path)
        response["content-type"] = content_type
        response["accept-ranges"] = "bytes"
        if request.env["HTTP_RANGE"] && (!request.env["HTTP_IF_RANGE"] || request.env["HTTP_IF_RANGE"] == etag)
          ranges = Rack::Utils.get_byte_ranges(request.env["HTTP_RANGE"], size)
          if ranges == []
            response["content-range"] = "bytes */#{size}"
            request.halt 416
          elsif ranges&.length == 1
            range = ranges.first
            length = range.end - range.begin + 1
            response["content-range"] = "bytes #{range.begin}-#{range.end}/#{size}"
            response["content-length"] = length.to_s
            request.halt [206, response.headers, FileBody.new(path, offset: range.begin, length: length)]
          end
        end
        response["content-length"] = size.to_s
        request.halt [200, response.headers, FileBody.new(path)]
      end

      def attachment(id)
        file = db[:attachments][id: id] || raise(Error.new("File not found", 404))
        repo.room(@user, db[:messages].where(id: file[:message_id]).get(:room_id))
        if request.params["variant"] == "thumb"
          variant = container.media.variant(file, :thumb) || raise(Error.new("Preview not available", 404))
          send_local_file(*variant)
        end
        inline = request.params["inline"] == "1" && (Uploads::IMAGE_TYPES.include?(file[:content_type]) ||
          file[:content_type].start_with?("video/", "audio/") || file[:content_type] == "application/pdf")
        response["content-disposition"] = "#{inline ? 'inline' : 'attachment'}; filename*=UTF-8''#{CGI.escape(file[:filename]).gsub('+', '%20')}"
        send_local_file(container.uploads.path(file[:key]), inline ? file[:content_type] : "application/octet-stream")
      end

      def logo
        account = repo.account
        small = request.params["size"] == "small"
        file = account && container.media.find("Account", account[:id], "logo")
        variant = container.media.variant(file, small ? :small_logo : :logo)
        path, type = variant || [File.expand_path("../../../public/original/logos/#{small ? 'app-icon-192.png' : 'app-icon.png'}", __dir__), "image/png"]
        send_local_file(path, type, cache: "public, max-age=300, stale-while-revalidate=604800")
      end

      def avatar(token)
        id = container.tokens.verify(token, purpose: :avatar)
        raise Error.new("Avatar not found", 404) unless id.is_a?(Integer)
        person = repo.user(id)
        file = container.media.find("User", id, "avatar")
        if variant = container.media.variant(file, :avatar)
          send_local_file(*variant, cache: "public, max-age=1800, stale-while-revalidate=604800")
        elsif person.bot?
          send_local_file(File.expand_path("../../../public/original/default-bot-avatar.svg", __dir__), "image/svg+xml")
        else
          response["content-type"] = "image/svg+xml"
          response["cache-control"] = "public, max-age=1800, stale-while-revalidate=604800"
          container.media.initials_svg(person)
        end
      end

      def qr_code(encoded)
        raise Error.new("Invalid QR content", 400) if encoded.bytesize > 4096
        value = Base64.urlsafe_decode64(encoded)
        response["content-type"] = "image/svg+xml"
        response["cache-control"] = "public, max-age=31536000"
        RQRCode::QRCode.new(value).as_svg(viewbox: true, fill: :white, color: :black)
      rescue ArgumentError, RQRCodeCore::QRCodeRunTimeError
        raise Error.new("Invalid QR content", 400)
      end

      def session_transfer(r, token)
        r.get(true) do
          ui.page("sessions/transfers/show")
        end
        r.put(true) do
          id = container.tokens.verify(token, purpose: :transfer)
          row = id.is_a?(Integer) && db[:users][id: id, status: 0]
          raise Error.new("Transfer link is invalid or expired", 400) unless row
          login(User.new(row))
          r.redirect "/"
        end
      end
    end
  end
end
