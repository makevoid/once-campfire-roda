# frozen_string_literal: true

module Campfire
  module Routes
    module CachedReads
      CACHE_HEADERS = %w[content-type content-encoding cache-control etag last-modified vary].freeze

      private

      # Call only after authentication and room authorization. All cookies and
      # presentation inputs are partitioned, and session mutations are not cached.
      def cached_read
        cache = container.response_cache
        version = @response_cache_version
        return yield unless version && request.get? && !@bot && !wants_json? && !wants_stream? &&
          !session["flash"] && !request.env["HTTP_IF_NONE_MATCH"] && !request.env["HTTP_IF_MODIFIED_SINCE"] && !db.in_transaction?

        encoding = Rack::Utils.select_best_encoding(%w[gzip identity], Rack::Utils.q_values(request.env["HTTP_ACCEPT_ENCODING"]))
        return yield unless encoding
        original_session = Marshal.dump(session)
        key = JSON.generate([request.fullpath, request.base_url, request.user_agent, encoding,
          request.env["HTTP_ACCEPT"], request.env["HTTP_TURBO_FRAME"], @user.id,
          Digest::SHA256.hexdigest(original_session), request.cookies.reject { |name, _| name == "session_token" }])
        return yield if key.bytesize > ResponseCache::MAX_KEY_BYTES

        entry = cache.read(key, version)
        rendered = false
        body = nil
        unless entry
          cache.synchronize_render(key, version) do
            entry = cache.read(key, version)
            if !entry && cache.version == version
              body = yield
              rendered = true
              if body.is_a?(String) && (response.status || 200) == 200 && response["content-type"].to_s.start_with?("text/html") &&
                  Marshal.dump(session) == original_session && !response["content-encoding"]
                body = encoding == "gzip" ? Zlib.gzip(body) : body.dup
                response["content-encoding"] = "gzip" if encoding == "gzip"
                response["vary"] = (response["vary"].to_s.split(/,\s*/) | ["Accept-Encoding"]).reject(&:empty?).join(", ")
                headers = response.headers.slice(*CACHE_HEADERS).transform_values { |value| value.dup.freeze }.freeze
                entry = {body: body.freeze, headers: headers}.freeze
                cache.write(key, version, entry)
              end
            end
          end
        end
        if entry
          response.headers.merge!(entry[:headers])
          entry[:body]
        elsif rendered
          body
        else
          yield
        end
      end
    end
  end
end
