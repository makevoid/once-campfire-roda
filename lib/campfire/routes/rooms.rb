# frozen_string_literal: true

module Campfire
  module Routes
    module Rooms
      private

      def room_page(around: nil)
        # Reading the cursor BEFORE the messages prevents a concurrent post from
        # being skipped by the next refresh. Duplicate deliveries are idempotent.
        cursor = db[:events].where(room_id: @room.id).max(:id) || 0
        page = repo.messages(@room.id, around: around)
        json(renderer.json_messages(page)) if wants_json?
        name = repo.room_name(@room, @user)
        content = renderer.template("room", room: @room, name: name, page: page, user: @user, csrf: csrf_token, cursor: cursor)
        full_page(name, content)
      end

      def room_management_routes(r, kind)
        type = {"opens" => "Rooms::Open", "closeds" => "Rooms::Closed", "directs" => "Rooms::Direct"}.fetch(kind)
        r.get("new") { room_form(kind) }
        r.post(true) do
          room = service.create_room(@user, r.params["room"] || {}, type: type, user_ids: Array(r.params["user_ids"]))
          json({id: room.id}, status: 201) if wants_json?
          r.redirect "/rooms/#{room.id}"
        end
        r.on Integer do |id|
          @room = repo.room(@user, id)
          raise Error.new("Room not found", 404) if @room.direct? != (kind == "directs")
          r.get("edit") { service.administer!(@user, @room); room_form(kind, @room) }
          r.is do
            r.get(true) { r.redirect "/rooms/#{id}" }
            r.patch(true) do
              service.update_room(@user, id, attributes("room"), type: type, user_ids: Array(r.params["user_ids"]))
              r.redirect "/rooms/#{id}"
            end
            r.delete(true) { service.delete_room(@user, id, direct_only: kind == "directs"); r.redirect "/" }
          end
        end
      end

      def room_form(kind, room = nil)
        fields = kind == "directs" ? [] : [{label: "Room name", name: "room[name]", value: room&.[](:name), required: true}]
        extras = +""
        if kind != "opens"
          selected = room ? db[:memberships].where(room_id: room.id).select_map(:user_id) : [request.params["user_id"].to_i]
          extras << '<fieldset><legend>Participants</legend>'
          db[:users].where(status: 0).exclude(id: @user.id).order(:name).each do |person|
            extras << %(<label class="checkbox"><input type="checkbox" name="user_ids[]" value="#{person[:id]}" #{selected.include?(person[:id]) ? 'checked' : ''}>#{renderer.h(person[:name])}</label>)
          end
          extras << '</fieldset>'
        end
        extras << '<p><a href="/rooms/opens/new">Open room</a> · <a href="/rooms/closeds/new">Private room</a> · <a href="/rooms/directs/new">Direct message</a></p>' unless room
        action = room ? "/rooms/#{kind}/#{room.id}" : "/rooms/#{kind}"
        full_page("Room", renderer.form(title: room ? "Edit room" : "New conversation", action: action, method: room ? "patch" : "post", csrf: csrf_token, fields: fields, extras: extras))
      end

      def room_settings
        options = %w[invisible nothing mentions everything].map { |value| %(<option #{value == @room[:involvement] ? 'selected' : ''}>#{value}</option>) }.join
        extras = %(<label>Notifications<select name="involvement">#{options}</select></label>)
        unless @room.direct?
          if @user.can_administer?(@room)
            kind = @room.open? ? "opens" : "closeds"
            extras << %(<p><a href="/rooms/#{kind}/#{@room.id}/edit">Edit room and participants</a></p>)
          end
        end
        content = renderer.form(title: repo.room_name(@room, @user), action: "/rooms/#{@room.id}/involvement", method: "patch", csrf: csrf_token, fields: [], extras: extras)
        if @room.direct? || @user.can_administer?(@room)
          action = @room.direct? ? "/rooms/directs/#{@room.id}" : "/rooms/#{@room.id}"
          content << renderer.form(title: "Delete conversation", action: action, method: "delete", csrf: csrf_token, fields: [], submit: "Delete room and its messages")
        end
        full_page("Room settings", content)
      end
    end
  end
end
