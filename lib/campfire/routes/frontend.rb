# frozen_string_literal: true

module Campfire
  module Routes
    module Frontend
      private

      def webmanifest
        view = ui
        logo = view.account_logo_url
        data = {name: repo.account&.fetch(:name) || "Campfire", short_name: "Campfire", start_url: "/", scope: "/", display: "standalone",
          description: "A chat app from the makers of Basecamp and HEY.", categories: %w[social business productivity],
          theme_color: "#ffffff", background_color: "#ffffff",
          icons: [{src: view.account_logo_url(size: :small), type: "image/png", sizes: "192x192"},
            {src: logo, type: "image/png", sizes: "512x512"}, {src: logo, type: "image/png", sizes: "512x512", purpose: "maskable"}],
          shortcuts: [{name: "New chat room", description: "Open Campfire and start a new chat room", url: "/rooms/opens/new", icons: [{src: view.asset_path("add.svg"), sizes: "any"}]},
            {name: "My profile", description: "Open Campfire and view your profile", url: "/users/me/profile", icons: [{src: view.asset_path("person.svg"), sizes: "any"}]}],
          screenshots: %w[android-chat android-sidebar android-dark-mode].map { |name| {src: view.asset_path("screenshots/#{name}.png"), sizes: "1080x2400", form_factor: "narrow"} }}
        response["content-type"] = "application/manifest+json"
        JSON.generate(data)
      end

      def autocomplete_users
        query = (request.params["filter"] || request.params["query"] || request.params["q"]).to_s[0, 100]
        rows = db[:users].where(status: 0)
        if room_id = request.params["room_id"]
          repo.room(@user, repo.integer(room_id))
          rows = rows.where(id: db[:memberships].where(room_id: room_id).select(:user_id))
        end
        rows = rows.where(Sequel.ilike(:name, "%#{query}%")) unless query.empty?
        offset = [[request.params["page"].to_i, 1].max - 1, 100_000].min * 20
        view = ui
        users = rows.order(Sequel.function(:lower, :name)).limit(20, offset).all.map { |row| UI::User.new(row, view.context) }
        if wants_json?
          json(users.map { |user| {name: CGI.escapeHTML(user.name), value: user.id, avatar_url: "#{request.base_url}#{view.avatar_url(user)}", sgid: user.attachable_sgid} })
        end
        view.render(partial: "autocompletable/users/prompt_item", collection: users, as: :user)
      end

      def refresh_room
        since = Time.at(repo.integer(request.params.fetch("since", "0")) / 1000.0).utc
        rows = db[:messages].where(room_id: @room.id)
        created = rows.where { created_at > since }.order(:created_at, :id).limit(40).all
        updated = rows.exclude(id: created.map { |row| row[:id] }).where { updated_at > since }.reverse_order(:created_at, :id).limit(40).all.reverse
        page = repo.present(created + updated)
        json(api_messages(page)) if wants_json?
        view = ui(page: page)
        output = +""
        unless created.empty?
          html = view.render(partial: "messages/message", collection: created.map { |row| view.context.message(row[:id]) })
          output << stream("append", "messages_room_#{@room.id}", html)
        end
        updated.each do |row|
          output << stream("replace", "message_#{row[:client_message_id]}", view.render(view.context.message(row[:id])))
        end
        response["content-type"] = "text/vnd.turbo-stream.html; charset=utf-8"
        output
      end

      def account_users_page
        view = ui
        rows = db[:users].where(status: 0).exclude(role: 2).order(Sequel.function(:lower, :name)).all
        page = UI::Pagination.new(rows, request.params["page"], per_page: 500)
        users = page.records.map { |row| UI::User.new(row, view.context) }
        output = stream("replace", "next_page_container", view.render(partial: "accounts/users/user", collection: users, as: :user))
        output << stream("append", "account_users", view.render("accounts/users/next_page_container", page: page.next_param)) unless page.last?
        output
      end
    end
  end
end
