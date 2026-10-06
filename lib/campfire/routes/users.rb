# frozen_string_literal: true

module Campfire
  module Routes
    module Users
      private

      def user_routes(r)
        r.on "me" do
          r.get "sidebar" do
            view = ui
            data = repo.sidebar(@user)
            assigns = view.context.sidebar(data)
            # CSRF masks vary per render; validators instead include all sidebar
            # records and user presentation timestamps, after authorization.
            fingerprint = JSON.generate([@user.id, data, db[:users].max(:updated_at), repo.account[:updated_at]])
            conditional_html(view.page("users/sidebars/show", assigns), fingerprint: fingerprint)
          end
          r.on "push_subscriptions" do
            r.get(true) do
              rows = db[:push_subscriptions].where(user_id: @user.id).all
              json({public_key: ENV["VAPID_PUBLIC_KEY"], subscriptions: rows.map { |row| row.slice(:id, :user_agent) }}) if wants_json?
              ui.page("users/push_subscriptions/index", push_subscriptions: rows.map { |row| UI::Record.new(row) })
            end
            r.post(true) do
              id = service.subscribe(@user, r.params["push_subscription"] || r.params["subscription"] || r.params, agent: r.user_agent)
              r.halt 200 if r.params["push_subscription"]
              json({id: id}, status: 201)
            end
            r.post Integer, "test_notifications" do |id|
              raise Error.new("Subscription not found", 404) unless db[:push_subscriptions][id: id, user_id: @user.id]
              JobQueue.new(db).enqueue("push_test", {subscription_id: id})
              r.redirect "/users/me/push_subscriptions"
            end
            r.delete(Integer) do |id|
              db[:push_subscriptions].where(id: id, user_id: @user.id).delete
              r.halt 204 if wants_json?
              r.redirect "/users/me/push_subscriptions"
            end
          end
          r.on "profile" do
            r.get(true) do
              view = ui
              memberships = view.context.memberships_for(@user.id).sort_by { |m| m.room.name.to_s.downcase }
              direct, shared = memberships.partition { |m| m.room.direct? }
              view.page("users/profiles/show", user: view.current.user, direct_memberships: direct, shared_memberships: shared)
            end
            r.patch(true) { update_profile }
            r.put(true) { update_profile }
          end
        end
        r.on Integer do |id|
          repo.user(id)
          r.get(true) do
            view = ui
            view.page("users/show", user: view.context.user(id))
          end
          r.on "ban" do
            r.post(true) { service.manage_user(@user, id, :ban); r.redirect "/users/#{id}" }
            r.delete(true) { service.manage_user(@user, id, :unban); r.redirect "/users/#{id}" }
          end
        end
      end

      def update_profile
        attrs = attributes("user")
        db.transaction(mode: :immediate) do
          service.update_profile(@user, attrs)
          container.media.replace("User", @user.id, "avatar", attrs["avatar"]) if attrs["avatar"]
        end
        session["flash"] = {"notice" => attrs["avatar"] ? "It may take up to 30 minutes to change everywhere." : "✓"}
        request.redirect "/users/me/profile"
      end
    end
  end
end
