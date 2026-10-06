# frozen_string_literal: true

module Campfire
  module Routes
    module Users
      private

      def user_routes(r)
        r.on "me" do
          r.get("sidebar") { conditional_html(renderer.sidebar(repo.sidebar(@user))) }
          r.on "push_subscriptions" do
            r.get(true) do
              json({public_key: ENV["VAPID_PUBLIC_KEY"], subscriptions: db[:push_subscriptions].where(user_id: @user.id).select(:id, :user_agent).all})
            end
            r.post(true) do
              id = service.subscribe(@user, r.params["subscription"] || r.params, agent: r.user_agent)
              json({id: id}, status: 201)
            end
            r.delete(Integer) do |id|
              db[:push_subscriptions].where(id: id, user_id: @user.id).delete
              r.halt 204
            end
          end
          r.on "profile" do
            r.get(true) do
              fields = [{label: "Name", name: "user[name]", value: @user[:name], required: true},
                {label: "Email", name: "user[email_address]", type: "email", value: @user[:email_address]},
                {label: "About you", name: "user[bio]", type: "textarea", value: @user[:bio]},
                {label: "New password (optional; signs out all sessions)", name: "user[password]", type: "password"}]
              extras = '<p><button type="button" id="enable-notifications">Enable notifications on this device</button></p>'
              full_page("Profile", renderer.form(title: "Your profile", action: "/users/me/profile", method: "patch", csrf: csrf_token, fields: fields, extras: extras))
            end
            r.patch(true) { service.update_profile(@user, attributes("user")); r.redirect "/users/me/profile" }
          end
        end
        r.on Integer do |id|
          person = repo.user(id)
          r.get(true) do
            content = %(<section class="panel"><h1>#{renderer.h(person[:name])}</h1><p>#{renderer.h(person[:bio])}</p><a href="/rooms/directs/new?user_id=#{id}">Start a direct message</a></section>)
            if @user.administrator? && id != @user.id
              content << renderer.form(title: person[:status] == 2 ? "Unban user" : "Ban user", action: "/users/#{id}/ban",
                method: person[:status] == 2 ? "delete" : "post", csrf: csrf_token, fields: [], submit: person[:status] == 2 ? "Unban" : "Ban and remove messages")
            end
            full_page(person[:name], content)
          end
          r.on "ban" do
            r.post(true) { service.manage_user(@user, id, :ban); r.redirect "/users/#{id}" }
            r.delete(true) { service.manage_user(@user, id, :unban); r.redirect "/users/#{id}" }
          end
        end
      end
    end
  end
end
