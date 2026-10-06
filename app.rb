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
require_relative "lib/campfire/routes/media"
require_relative "lib/campfire/routes/frontend"

module Campfire
  class App < Roda
    include Routes::Support
    include Routes::Messages
    include Routes::Rooms
    include Routes::Users
    include Routes::Account
    include Routes::Media
    include Routes::Frontend

    SECRET = Authentication.session_secret.freeze

    use RequestLimit
    use Rack::MethodOverride
    plugin :all_verbs
    plugin :head
    plugin :halt
    plugin :json
    plugin :type_routing, exclude: [:xml], types: {turbo_stream: "text/vnd.turbo-stream.html"}
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
        %(<section class="panel"><h1>#{CGI.escapeHTML(error.message)}</h1><a href="/">Back to Campfire</a></section>)
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
      response["content-type"] = "text/html; charset=utf-8"
      response["x-content-type-options"] = "nosniff"
      response["referrer-policy"] = "same-origin"
      response["x-frame-options"] = "DENY"
      @nonce = SecureRandom.base64(18)
      response["content-security-policy"] = "default-src 'self'; script-src 'self' 'nonce-#{@nonce}'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: https:; media-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
      response["cache-control"] = "private, no-store"
      r.get("up") { "OK" }
      r.get("service-worker") { send_local_file(File.expand_path("public/service-worker.js", __dir__), "text/javascript", cache: "no-cache") }
      r.public if r.path == "/service-worker.js" || r.path.start_with?("/assets/")
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
      r.get("account", "logo") { logo }
      r.get("qr_code", String) { |value| qr_code(value) }
      r.on "first_run" do
        r.redirect "/" if repo.account
        r.get(true) { auth_form("Set up Campfire", "/first_run", registration: true) }
        r.post(true) do
          user = register_user { service.setup(attributes("user")) }
          login(user)
          r.redirect "/"
        end
      end

      r.on "join", String do |code|
        raise Error.new("Invalid invitation", 404) unless repo.account&.fetch(:join_code) == code
        r.get(true) { auth_form("Join Campfire", "/join/#{code}", registration: true) }
        r.post(true) do
          user = register_user { service.join(code, attributes("user")) }
          login(user)
          r.redirect "/"
        end
      end

      r.on "session" do
        r.on("transfers", String) { |token| session_transfer(r, token) }
        r.get "new" do
          r.redirect "/first_run" unless repo.account
          auth_form("Welcome back", "/session")
        end
        r.post(true) do
          return_to = session["return_to"] || "/"
          login(auth.authenticate(r.params["email_address"], r.params["password"], ip: r.ip))
          r.redirect return_to
        rescue Error => error
          raise unless [401, 429].include?(error.status)
          response.status = error.status
          ui(flash: {alert: "Too many requests or unauthorized."}).page("sessions/new")
        end
        r.delete(true) do
          if person = auth.resume(session["token"])
            db[:push_subscriptions].where(user_id: person.id, endpoint: r.params["push_subscription_endpoint"]).delete if r.params["push_subscription_endpoint"]
          end
          auth.terminate(session["token"])
          session.clear
          r.redirect "/session/new"
        end
      end

      r.get("webmanifest") { webmanifest }
      @user = auth.resume(session["token"])
      r.get "cable" do
        raise Error.new("Sign in required", 401) unless @user
        raise Error.new("Invalid WebSocket origin", 403) unless r.env["HTTP_ORIGIN"] == r.base_url
        raise Error.new("WebSocket upgrade required", 426) unless WebSocket::Driver.websocket?(r.env) && r.env["rack.hijack"]
        Realtime::Socket.new(container, r, session["token"], csrf_token)
        r.halt [-1, {}, []]
      end
      unless @user
        session["return_to"] = r.fullpath if r.get? && r.fullpath.start_with?("/") && !r.fullpath.start_with?("//")
        r.redirect(repo.account ? "/session/new" : "/first_run")
      end

      r.root do
        memberships = db[:memberships].where(user_id: @user.id)
        room_id = memberships.where(room_id: session["last_room_id"]).get(:room_id) || memberships.order(:id).get(:room_id)
        r.redirect "/rooms/#{room_id}" if room_id
        ui.page("welcome/show")
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
            r.get(true) do
              view = ui
              view.page("rooms/involvements/show", room: view.context.room(id), involvement: @room[:involvement])
            end
            r.is do
              r.on(r.patch? || r.put?) do
                service.involvement(@user, id, r.params["involvement"])
                r.redirect "/rooms/#{id}/involvement"
              end
            end
          end
          r.post("heartbeat") { service.heartbeat(@user, id); r.halt 204 }
          r.get("events") { events }
          r.get("refresh") { refresh_room }
        end
      end

      # Rails exposes both nested and global message URLs.
      r.on "messages", Integer do |id|
        room_id = db[:messages].where(id: id).get(:room_id) || raise(Error.new("Message not found", 404))
        @room = repo.room(@user, room_id)
        message_detail_routes(r, id)
      end

      r.on "users", String, "avatar" do |token|
        r.get(true) { avatar(token) }
        r.delete(true) { container.media.remove("User", @user.id, "avatar"); r.redirect "/users/me/profile" }
      end
      r.on("users") { user_routes(r) }
      r.on("account") { account_routes(r) }
      r.post("unfurl_link") do
        data = OpenGraph.new.from_url(r.params["url"])
        r.halt 204 unless data
        json(data)
      end
      r.on "autocompletable", "users" do
        r.get(true) { autocomplete_users }
      end

      r.on "searches" do
        r.get(true) do
          query = r.params["q"].to_s[0, 500]
          page = repo.search(@user, query)
          json(api_messages(page)) if wants_json?
          view = ui(page: page)
          view.page("searches/index", query: query.empty? ? nil : query.gsub(/[^[:word:]]/, " "), messages: view.context.page_messages(page),
            recent_searches: db[:searches].where(user_id: @user.id).reverse_order(:updated_at).limit(10).all.map { |row| UI::Record.new(row) },
            return_to_room: view.last_room_visited)
        end
        r.post(true) do
          service.record_search(@user, r.params["q"])
          r.redirect "/searches?q=#{CGI.escape(r.params['q'].to_s[0, 500])}"
        end
        r.delete("clear") { db[:searches].where(user_id: @user.id).delete; r.redirect "/searches" }
      end

      r.get "attachments", Integer do |id|
        attachment(id)
      end
    end

  end

end
