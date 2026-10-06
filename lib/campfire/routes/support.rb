# frozen_string_literal: true

module Campfire
  module Routes
    module Support
      private

      def container = opts[:container]

      def db = container.db

      def repo = container.repo

      def auth = container.auth

      def service = container.service

      def ui(page: nil, flash: nil)
        UI::View.new(container: container, actor: @user, request: request, csrf: csrf_token,
          nonce: @nonce, page: page, last_room_id: session["last_room_id"], flash: flash || session.delete("flash")&.transform_keys(&:to_sym) || {})
      end

      def stream(action, target, html = "")
        response["content-type"] = "text/vnd.turbo-stream.html; charset=utf-8"
        %(<turbo-stream action="#{action}" target="#{CGI.escapeHTML(target.to_s)}"><template>#{html}</template></turbo-stream>)
      end

      def wants_stream? = request.requested_type == :turbo_stream || request.params["format"] == "turbo_stream"

      def wants_json? = @bot || request.requested_type == :json || request.params["format"] == "json"

      def api_messages(page) = API.new(ui(page: page)).messages(page)

      def attributes(key)
        value = request.params[key]
        raise Error.new("Missing #{key} parameters", 400) unless value.is_a?(Hash)
        value
      end

      def json(value, status: 200)
        response["content-type"] = "application/json; charset=utf-8"
        request.halt status, JSON.generate(value)
      end

      def login(user)
        auth.terminate(session["token"]) if session["token"]
        session.clear
        session["token"] = auth.start(user, ip: request.ip, agent: request.user_agent)
      end

      def register_user
        db.transaction(mode: :immediate) do
          user = yield
          container.media.replace("User", user.id, "avatar", attributes("user")["avatar"])
          user
        end
      end

      def auth_form(title, action, registration: false)
        view = ui
        if registration
          view.params[:join_code] = action.delete_prefix("/join/")
          view.page(action == "/first_run" ? "first_runs/show" : "users/new", user: UI::User.new({}, view.context))
        else
          view.page("sessions/new")
        end
      end

      def conditional_html(html, fingerprint: nil)
        # Compute after authorization; validators cannot be reused across users.
        etag = %Q{"#{Digest::SHA256.hexdigest(fingerprint || html)}"}
        response["etag"] = etag
        response["cache-control"] = "private, no-cache"
        response["vary"] = "Cookie, Accept"
        request.halt 304 if request.env["HTTP_IF_NONE_MATCH"] == etag
        html
      end
    end
  end
end
