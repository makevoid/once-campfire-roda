# frozen_string_literal: true

module Campfire
  module Routes
    module Messages
      private

      def message_attributes
        if @bot && !request.media_type.to_s.include?("json") && !request.media_type.to_s.include?("form")
          body = request.body.read(100_001).to_s
          {"body" => request.media_type == "text/html" ? body : CGI.escapeHTML(body).gsub("\n", "<br>")}
        elsif @bot
          request.params["message"] || request.params
        else
          attributes("message")
        end
      end

      def message_routes(r)
        r.is do
          r.get(true) do
            page = repo.messages(@room.id, before: r.params["before"], after: r.params["after"])
            if @bot
              response["x-total-count"] = db[:messages].where(room_id: @room.id).count.to_s
              unless page.empty?
                direction = r.params["after"] ? "after" : "before"
                id = direction == "after" ? page.messages.last[:id] : page.messages.first[:id]
                response["link"] = %(<#{r.path}?#{direction}=#{id}>; rel="next") if page.messages.length == Repository::PAGE_SIZE
              end
            end
            json(renderer.json_messages(page)) if wants_json?
            r.halt 204 if page.empty?
            conditional_html(renderer.messages(page, user: @user))
          end
          r.post(true) do
            message = service.post_message(@user, @room.id, message_attributes)
            response["location"] = "/rooms/#{@room.id}/messages/#{message[:id]}"
            if wants_json?
              json(renderer.json_messages(repo.present([message])).first, status: 201)
            end
            r.redirect "/rooms/#{@room.id}"
          end
        end
        r.on(Integer) { |id| message_detail_routes(r, id) }
      end

      def message_detail_routes(r, id)
        message = repo.message(@room.id, id)
        r.is do
          r.get(true) do
            page = repo.present([message])
            json(renderer.json_messages(page).first) if wants_json?
            full_page("Message", renderer.messages(page, user: @user))
          end
          r.patch(true) { update_message(id) }
          r.put(true) { update_message(id) }
          r.delete(true) do
            service.delete_message(@user, @room.id, id)
            r.halt 204 if wants_json?
            r.redirect "/rooms/#{@room.id}"
          end
        end
        r.get "edit" do
          service.administer!(@user, message)
          content = renderer.form(title: "Edit message", action: "/rooms/#{@room.id}/messages/#{id}", csrf: csrf_token, method: "patch",
            fields: [{label: "Message (HTML supported)", name: "message[body]", type: "textarea", value: message[:body]}])
          full_page("Edit message", content)
        end
        r.on "boosts" do
          r.is do
            r.get(true) { json(renderer.json_messages(repo.present([message])).first[:boosts]) }
            r.post(true) do
              content = (r.params["boost"] || r.params)["content"]
              content = r.body.read(65) if @bot && r.media_type == "text/plain"
              id = service.boost(@user, @room.id, message[:id], content)
              json({id: id}, status: 201) if wants_json?
              r.redirect "/rooms/#{@room.id}"
            end
          end
          r.delete(Integer) { |boost_id| service.unboost(@user, @room.id, id, boost_id); r.halt 204 }
        end
      end

      def update_message(id)
        message = service.edit_message(@user, @room.id, id, message_attributes)
        json(renderer.json_messages(repo.present([message])).first) if wants_json?
        request.redirect "/rooms/#{@room.id}/messages/#{id}"
      end

      def events
        since = [repo.integer(request.params.fetch("after", "0")), 0].max
        rows = db[:events].where(room_id: @room.id).where { id > since }.order(:id).limit(100).all
        changed = rows.reject { |e| e[:kind] == "delete" }.map { |e| e[:message_id] }.uniq
        page = repo.present(db[:messages].where(room_id: @room.id, id: changed).order(:created_at, :id).all)
        json({cursor: rows.last&.fetch(:id) || since, more: rows.length == 100,
          deleted: rows.select { |e| e[:kind] == "delete" }.map { |e| e[:message_id] },
          html: renderer.messages(page, user: @user)})
      end
    end
  end
end
