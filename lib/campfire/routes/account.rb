# frozen_string_literal: true

module Campfire
  module Routes
    module Account
      private

      def account_routes(r)
        service.admin!(@user)
        r.get("edit") { account_page }
        r.get(true) { account_page }
        r.patch(true) do
          attrs = attributes("account")
          settings = {restrict_room_creation_to_administrators: attrs["restrict_room_creation_to_administrators"] == "true"}
          db[:accounts].update(name: service.required(attrs["name"], "Account name", 100), settings: JSON.generate(settings), updated_at: Time.now.utc)
          r.redirect "/account/edit"
        end
        r.post("join_code") { db[:accounts].update(join_code: SecureRandom.hex(16), updated_at: Time.now.utc); r.redirect "/account/edit" }
        r.on "users", Integer do |id|
          r.patch(true) { service.manage_user(@user, id, :role, role: attributes("user")["role"]); r.redirect "/account/edit" }
          r.delete(true) { service.manage_user(@user, id, :deactivate); r.redirect "/account/edit" }
        end
        r.on "bots" do
          r.get("new") do
            full_page("New bot", renderer.form(title: "New bot", action: "/account/bots", csrf: csrf_token, fields: [{label: "Bot name", name: "user[name]", required: true}, {label: "Webhook URL (optional)", name: "user[webhook_url]", type: "url"}]))
          end
          r.get(true) do
            body = +'<section class="panel"><h1>Bots</h1><a href="/account/bots/new">Create a bot</a>'
            db[:users].where(role: 2, status: 0).order(:name).each do |bot|
              body << %(<h2>#{renderer.h(bot[:name])}</h2><p>Key: <code>#{bot[:id]}-#{bot[:bot_token]}</code></p><a href="/account/bots/#{bot[:id]}/edit">Edit name and webhook</a>)
              body << renderer.form(title: "Rotate key", action: "/account/bots/#{bot[:id]}/key", method: "patch", csrf: csrf_token, fields: [], submit: "Rotate bot key")
              body << renderer.form(title: "Deactivate bot", action: "/account/bots/#{bot[:id]}", method: "delete", csrf: csrf_token, fields: [], submit: "Deactivate")
            end
            full_page("Bots", body << '</section>')
          end
          r.post(true) do
            bot = db.transaction(mode: :immediate) do
              bot = service.create_user(attributes("user"), role: 2)
              service.update_bot(@user, bot.id, attributes("user"))
              bot
            end
            json({id: bot.id, key: "#{bot.id}-#{bot[:bot_token]}"}, status: 201) if wants_json?
            r.redirect "/account/bots"
          end
          r.on Integer do |id|
            bot = repo.user(id)
            raise Error.new("Bot not found", 404) unless bot.bot?
            r.get("edit") do
              full_page("Edit bot", renderer.form(title: "Edit bot", action: "/account/bots/#{id}", method: "patch", csrf: csrf_token,
                fields: [{label: "Bot name", name: "user[name]", value: bot[:name], required: true},
                  {label: "Webhook URL (optional)", name: "user[webhook_url]", type: "url", value: db[:webhooks].where(user_id: id).get(:url)}]))
            end
            r.patch(true) { service.update_bot(@user, id, attributes("user")); r.redirect "/account/bots" }
            r.patch("key") { db[:users].where(id: id).update(bot_token: SecureRandom.hex(24), updated_at: Time.now.utc); r.redirect "/account/bots" }
            r.delete(true) { service.manage_user(@user, id, :deactivate); r.redirect "/account/bots" }
          end
        end
      end

      def account_page
        account = repo.account
        restricted = JSON.parse(account[:settings])["restrict_room_creation_to_administrators"]
        extras = %(<label class="checkbox"><input type="checkbox" name="account[restrict_room_creation_to_administrators]" value="true" #{restricted ? 'checked' : ''}>Only administrators can create rooms</label>)
        content = renderer.form(title: "Account settings", action: "/account", method: "patch", csrf: csrf_token,
          fields: [{label: "Account name", name: "account[name]", value: account[:name], required: true}], extras: extras)
        content << %(<section class="panel"><h2>Invite people</h2><a href="/join/#{account[:join_code]}">/join/#{account[:join_code]}</a><p><a href="/account/bots">Manage bots</a></p></section>)
        content << renderer.form(title: "Reset invitation", action: "/account/join_code", csrf: csrf_token, fields: [], submit: "Generate a new invitation")
        content << '<section class="panel"><h2>People</h2>'
        db[:users].exclude(role: 2).order(:name).limit(500).each do |person|
          content << %(<p><a href="/users/#{person[:id]}">#{renderer.h(person[:name])}</a> · #{person[:role] == 1 ? 'Administrator' : 'Member'} · #{%w[Active Deactivated Banned][person[:status]]}</p>)
          if person[:status] == 0
            content << renderer.form(title: "Change role", action: "/account/users/#{person[:id]}", method: "patch", csrf: csrf_token, fields: [],
              extras: '<label>Role<select name="user[role]"><option>member</option><option>administrator</option></select></label>')
            content << renderer.form(title: "Deactivate", action: "/account/users/#{person[:id]}", method: "delete", csrf: csrf_token, fields: [], submit: "Deactivate user") unless person[:id] == @user.id
          end
        end
        full_page("Account", content << '</section>')
      end
    end
  end
end
