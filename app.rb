# frozen_string_literal: true

require "bundler/setup"
require "roda"
require "rack/method_override"
require_relative "lib/campfire"
require_relative "lib/campfire/request_limit"
require_relative "lib/campfire/routes/support"
require_relative "lib/campfire/routes/messages"
require_relative "lib/campfire/routes/rooms"
require_relative "lib/campfire/routes/users"
require_relative "lib/campfire/routes/account"

module Campfire
  class App < Roda
    include Routes::Support
    include Routes::Messages
    include Routes::Rooms
    include Routes::Users
    include Routes::Account

    SECRET = if ENV["SESSION_SECRET"]
      ENV.fetch("SESSION_SECRET")
    elsif ENV["RACK_ENV"] == "production"
      raise "Set SESSION_SECRET to at least 64 random bytes in production"
    else
      path = File.expand_path("storage/session-secret", __dir__)
      FileUtils.mkdir_p(File.dirname(path))
      begin
        File.write(path, SecureRandom.hex(64), mode: File::WRONLY | File::CREAT | File::EXCL, perm: 0o600)
      rescue Errno::EEXIST
        # Shared by local server processes and retained across restarts.
      end
      File.read(path)
    end.freeze

    use RequestLimit
    use Rack::MethodOverride
    plugin :all_verbs
    plugin :head
    plugin :halt
    plugin :json
    plugin :json_parser, content_type_regexp: /\Aapplication\/json\b/i
    plugin :public, root: File.expand_path("public", __dir__)
    plugin :sessions, secret: SECRET, key: "session_token", max_seconds: Authentication::SESSION_TTL,
      cookie_options: {same_site: :lax, httponly: true, secure: ENV["RACK_ENV"] == "production" && ENV["DISABLE_SSL"] != "true"}
    # General tokens support the Rails benchmark client and JavaScript mutations.
    # Tokens are tied to an encrypted session and rotated at authentication.
    plugin :route_csrf, field: "authenticity_token", require_request_specific_tokens: false,
      check_header: true, csrf_failure: :empty_403, exempt_request_methods: %w[GET HEAD OPTIONS]
    plugin :error_handler do |error|
      case error
      when Error
        response.status = error.status
        response["content-type"] = "text/html; charset=utf-8"
        %(<section class="panel"><h1>#{renderer.h(error.message)}</h1><a href="/">Back to Campfire</a></section>)
      when Sequel::UniqueConstraintViolation
        response.status = 409
        "That email address or record already exists."
      else
        warn "#{error.class}: #{error.message}\n#{error.backtrace.first(10).join("\n")}"
        response.status = 500
        "Something went wrong."
      end
    end

    def self.build(container)
      Class.new(self) do
        opts[:container] = container
      end.freeze
    end

    route do |r|
      response["x-content-type-options"] = "nosniff"
      response["referrer-policy"] = "same-origin"
      response["x-frame-options"] = "DENY"
      response["content-security-policy"] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
      response["cache-control"] = "private, no-store"
      r.get("up") { "OK" }
      r.public if %w[/app.css /app.js /service-worker.js].include?(r.path)
      if !r.get? && !r.head?
        raise Error.new("Request too large", 413) if r.content_length.to_i > Uploads::MAX_SIZE + 1_048_576
        raise Error.new("Too many requests", 429) if db[:bans].where(ip_address: r.ip).any?
      end

      # Bot credentials are checked before the session/CSRF branch. Human cookies
      # never authorize this branch, and every operation still checks membership.
      r.on "rooms", Integer, /(\d+-[A-Za-z0-9]+)/ do |room_id, key|
        @user = auth.bot(key)
        raise Error.new("Invalid bot key", 401) unless @user
        @bot = true
        @room = repo.room(@user, room_id)
        r.on("messages") { message_routes(r) }
      end

      check_csrf!
      r.on "first_run" do
        r.redirect "/" if repo.account
        r.get(true) { auth_form("Set up Campfire", "/first_run", registration: true) }
        r.post(true) do
          login(service.setup(attributes("user")))
          r.redirect "/"
        end
      end

      r.on "join", String do |code|
        raise Error.new("Invalid invitation", 404) unless repo.account&.fetch(:join_code) == code
        r.get(true) { auth_form("Join Campfire", "/join/#{code}", registration: true) }
        r.post(true) do
          login(service.join(code, attributes("user")))
          r.redirect "/"
        end
      end

      r.on "session" do
        r.get "new" do
          r.redirect "/first_run" unless repo.account
          auth_form("Welcome back", "/session")
        end
        r.post(true) do
          login(auth.authenticate(r.params["email_address"], r.params["password"], ip: r.ip))
          r.redirect "/"
        end
        r.delete(true) do
          auth.terminate(session["token"])
          session.clear
          r.redirect "/session/new"
        end
      end

      r.get "webmanifest" do
        {name: "Campfire", short_name: "Campfire", start_url: "/", display: "standalone", theme_color: "#242d35", background_color: "#faf9f6"}
      end
      @user = auth.resume(session["token"])
      unless @user
        r.redirect(repo.account ? "/session/new" : "/first_run")
      end

      r.root do
        room_id = db[:memberships].where(user_id: @user.id).order(:id).get(:room_id)
        r.redirect "/rooms/#{room_id}" if room_id
        full_page("Welcome", '<section class="panel"><h1>Welcome to Campfire</h1><p>You have no rooms yet.</p><a href="/rooms/opens/new">Create a room</a></section>')
      end

      r.on "rooms" do
        r.is do
          r.get(true) { r.redirect "/" }
        end
        r.on(/(opens|closeds|directs)/) { |kind| room_management_routes(r, kind) }
        r.on Integer do |id|
          @room = repo.room(@user, id)
          r.get(true) { room_page } if r.remaining_path.empty?
          r.delete(true) { service.delete_room(@user, id); r.redirect "/" } if r.remaining_path.empty?
          r.get(/@(\d+)/) { |message_id| room_page(around: message_id) }
          r.get("settings") { room_settings }
          r.on("messages") { message_routes(r) }
          r.on "involvement" do
            r.get(true) { room_settings }
            r.patch(true) { service.involvement(@user, id, r.params["involvement"]); r.redirect "/rooms/#{id}" }
          end
          r.post("heartbeat") { service.heartbeat(@user, id); r.halt 204 }
          r.get("events") { events }
          r.get("refresh") do
            since = Time.at(repo.integer(r.params.fetch("since", "0")) / 1000.0).utc
            rows = db[:messages].where(room_id: id).where { updated_at > since }.order(:updated_at, :id).limit(80).all
            json(renderer.json_messages(repo.present(rows)))
          end
        end
      end

      # Rails exposes both nested and global message URLs.
      r.on "messages", Integer do |id|
        room_id = db[:messages].where(id: id).get(:room_id) || raise(Error.new("Message not found", 404))
        @room = repo.room(@user, room_id)
        message_detail_routes(r, id)
      end

      r.on("users") { user_routes(r) }
      r.on("account") { account_routes(r) }
      r.on "autocompletable", "users" do
        r.get(true) do
          query = r.params["q"].to_s[0, 100]
          rows = db[:users].where(status: 0).where(Sequel.ilike(:name, "%#{db.literal_like(query)}%"))
            .order(:name).limit(20).select(:id, :name).all
          json(rows)
        end
      end

      r.on "searches" do
        r.get(true) do
          query = r.params["q"].to_s[0, 500]
          page = repo.search(@user, query)
          json(renderer.json_messages(page)) if wants_json?
          content = renderer.template("search", query: query, page: page, user: @user, csrf: csrf_token,
            recent: db[:searches].where(user_id: @user.id).reverse_order(:updated_at).limit(10).all)
          full_page("Search", content)
        end
        r.post(true) do
          service.record_search(@user, r.params["q"])
          r.redirect "/searches?q=#{CGI.escape(r.params['q'].to_s[0, 500])}"
        end
        r.delete("clear") { db[:searches].where(user_id: @user.id).delete; r.redirect "/searches" }
      end

      r.get "attachments", Integer do |id|
        attachment = db[:attachments][id: id] || raise(Error.new("File not found", 404))
        room_id = db[:messages].where(id: attachment[:message_id]).get(:room_id)
        repo.room(@user, room_id)
        path = container.uploads.path(attachment[:key])
        raise Error.new("File not found", 404) unless File.file?(path)
        inline = r.params["inline"] == "1" && Uploads::IMAGE_TYPES.include?(attachment[:content_type])
        headers = response.headers.merge("content-type" => inline ? attachment[:content_type] : "application/octet-stream",
          "content-disposition" => "#{inline ? 'inline' : 'attachment'}; filename*=UTF-8''#{CGI.escape(attachment[:filename]).gsub('+', '%20')}",
          "content-length" => File.size(path).to_s)
        r.halt [200, headers, FileBody.new(path)]
      end
    end

  end

  class FileBody
    def initialize(path) = @path = path
    def each
      File.open(@path, "rb") do |file|
        while (chunk = file.read(64 * 1024))
          yield chunk
        end
      end
    end
  end
end
