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

      def renderer = container.renderer

      def wants_json? = @bot || request.env["HTTP_ACCEPT"].to_s.include?("application/json")

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

      def full_page(title, content)
        response["content-type"] = "text/html; charset=utf-8"
        renderer.page(title: title, content: content, csrf: csrf_token, user: @user,
          sidebar: @user && renderer.sidebar(repo.sidebar(@user)))
      end

      def auth_form(title, action, registration: false)
        prefix = registration ? "user" : nil
        fields = []
        fields << {label: "Your name", name: "user[name]", required: true} if registration
        fields << {label: "Email address", name: prefix ? "#{prefix}[email_address]" : "email_address", type: "email", required: true}
        fields << {label: "Password", name: prefix ? "#{prefix}[password]" : "password", type: "password", required: true}
        full_page(title, renderer.form(title: title, action: action, csrf: csrf_token, fields: fields, submit: registration ? "Get started" : "Sign in"))
      end

      def conditional_html(html)
        # Compute after authorization; validators cannot be reused across users.
        etag = %Q{"#{Digest::SHA256.hexdigest(html)}"}
        response["etag"] = etag
        response["cache-control"] = "private, no-cache"
        response["vary"] = "Cookie, Accept"
        request.halt 304 if request.env["HTTP_IF_NONE_MATCH"] == etag
        html
      end
    end
  end
end
