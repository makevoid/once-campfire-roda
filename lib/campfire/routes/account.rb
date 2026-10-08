# frozen_string_literal: true

module Campfire
  module Routes
    module Account
      private

      def account_routes(r)
        r.get("edit") { account_page }
        r.get(true) { account_page }
        r.get("users") { account_users_page }
        r.get("custom_styles.css") do
          response["content-type"] = "text/css; charset=utf-8"
          repo.account[:custom_styles].to_s
        end
        service.admin!(@user)
        r.patch(true) { update_account }
        r.put(true) { update_account }
        r.delete("logo") { container.media.remove("Account", repo.account[:id], "logo"); r.redirect "/account/edit" }
        r.on "custom_styles" do
          r.get("edit") do
            view = ui
            view.page("accounts/custom_styles/edit", account: view.current.account)
          end
          r.is(r.patch? || r.put?) do
            css = attributes("account")["custom_styles"].to_s
            raise Error, "Styles are too large" if css.bytesize > 100_000
            db[:accounts].update(custom_styles: css, updated_at: Time.now.utc)
            r.redirect "/account/custom_styles/edit"
          end
        end
        r.post("join_code") { db[:accounts].update(join_code: SecureRandom.hex(16), updated_at: Time.now.utc); r.redirect "/account/edit" }
        r.on "users", Integer do |id|
          r.is(r.patch? || r.put?) { service.manage_user(@user, id, :role, role: attributes("user")["role"]); r.redirect "/account/edit" }
          r.delete(true) { service.manage_user(@user, id, :deactivate); r.redirect "/account/edit" }
        end
        r.on "bots" do
          r.get("new") do
            view = ui
            view.page("accounts/bots/new", bot: UI::User.new({role: 2}, view.context))
          end
          r.get(true) do
            view = ui
            bots = db[:users].where(role: 2, status: 0).order(:name).all.map { |row| UI::User.new(row, view.context) }
            view.page("accounts/bots/index", bots: bots)
          end
          r.post(true) do
            bot = db.transaction(mode: :immediate) do
              bot = service.create_user(attributes("user"), role: 2)
              service.update_bot(@user, bot.id, attributes("user"))
              container.media.replace("User", bot.id, "avatar", attributes("user")["avatar"])
              bot
            end
            json({id: bot.id, key: "#{bot.id}-#{bot[:bot_token]}"}, status: 201) if wants_json?
            r.redirect "/account/bots"
          end
          r.on Integer do |id|
            bot = repo.user(id)
            raise Error.new("Bot not found", 404) unless bot.bot?
            r.get("edit") do
              view = ui
              view.page("accounts/bots/edit", bot: view.context.user(id))
            end
            r.is(r.patch? || r.put?) do
              db.transaction(mode: :immediate) do
                service.update_bot(@user, id, attributes("user"))
                container.media.replace("User", id, "avatar", attributes("user")["avatar"])
              end
              r.redirect "/account/bots"
            end
            r.is("key", r.patch? || r.put?) { db[:users].where(id: id).update(bot_token: SecureRandom.hex(24), updated_at: Time.now.utc); r.redirect "/account/bots" }
            r.delete(true) { service.manage_user(@user, id, :deactivate); r.redirect "/account/bots" }
          end
        end
      end

      def update_account
        attrs = attributes("account")
        db.transaction(mode: :immediate) do
          changes = {updated_at: Time.now.utc}
          changes[:name] = service.required(attrs["name"], "Account name", 100) if attrs.key?("name")
          setting = (attrs["settings"] || attrs)["restrict_room_creation_to_administrators"]
          unless setting.nil?
            settings = JSON.parse(repo.account[:settings]).merge("restrict_room_creation_to_administrators" => %w[1 true].include?(setting.to_s))
            changes[:settings] = JSON.generate(settings)
          end
          db[:accounts].update(changes)
          container.media.replace("Account", repo.account[:id], "logo", attrs["logo"]) if attrs["logo"]
        end
        request.redirect "/account/edit"
      end

      def visible_account_users
        db[:users].where(status: @user.administrator? ? [0, 2] : 0).order(Sequel.function(:lower, :name), :id)
      end

      def account_page
        view = ui
        rows = visible_account_users
        administrators = rows.where(role: 1).all.map { |row| UI::User.new(row, view.context) }
        page = UI::Pagination.new(rows.where(role: 0), request.params["page"], per_page: 500)
        members = page.records.map { |row| UI::User.new(row, view.context) }
        view.page("accounts/edit", account: view.current.account, administrators: administrators, members: members, page: page)
      end
    end
  end
end
