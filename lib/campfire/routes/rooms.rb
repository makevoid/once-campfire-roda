# frozen_string_literal: true

module Campfire
  module Routes
    module Rooms
      private

      def room_page(around: nil)
        page = repo.messages(@room.id, around: around)
        json(api_messages(page)) if wants_json?
        session["last_room_id"] = @room.id
        view = ui(page: page)
        view.page("rooms/show", room: view.context.room(@room.id), messages: view.context.page_messages(page))
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
          r.get("edit") { room_form(kind, @room) }
          r.is do
            r.get(true) { r.redirect "/rooms/#{id}" }
            r.on(r.patch? || r.put?) do
              service.update_room(@user, id, attributes("room"), type: type, user_ids: Array(r.params["user_ids"]))
              r.redirect "/rooms/#{id}"
            end
            r.delete(true) { service.delete_room(@user, id, direct_only: kind == "directs"); r.redirect "/" }
          end
        end
      end

      def room_form(kind, room = nil)
        restricted = JSON.parse(repo.account[:settings] || "{}")["restrict_room_creation_to_administrators"]
        raise Error.new("Only administrators can create rooms", 403) if !room && kind != "directs" && restricted && !@user.administrator?
        view = ui
        type = {"opens" => "Rooms::Open", "closeds" => "Rooms::Closed", "directs" => "Rooms::Direct"}.fetch(kind)
        model = UI::Room.new((room ? room.attributes : {name: "New room", creator_id: @user.id}).merge(type: type), view.context)
        users = db[:users].where(status: 0).order(Sequel.function(:lower, :name)).all.map { |row| UI::User.new(row, view.context) }
        selected_ids = room ? db[:memberships].where(room_id: room.id).select_map(:user_id) : [@user.id]
        selected, unselected = users.partition { |user| selected_ids.include?(user.id) }
        view.page("rooms/#{kind}/#{room ? 'edit' : 'new'}", room: model, users: users, selected_users: selected, unselected_users: unselected)
      end

      def room_settings
        kind = @room.direct? ? "directs" : @room.open? ? "opens" : "closeds"
        room_form(kind, @room)
      end
    end
  end
end
