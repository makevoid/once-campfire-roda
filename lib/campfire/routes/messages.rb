# frozen_string_literal: true

module Campfire
  module Routes
    module Messages
      private

      def message_attributes
        if @bot
          if request.media_type.to_s.include?("multipart") && request.params["attachment"]
            {"attachment" => request.params["attachment"]}
          else
            request.body.rewind
            {"body" => request.body.read(100_001).to_s}
          end
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
                remaining = direction == "after" ? repo.messages(@room.id, after: id) : repo.messages(@room.id, before: id)
                response["link"] = %(<#{r.base_url}#{r.path}?#{direction}=#{id}>; rel="next") unless remaining.empty?
              end
            end
            json(api_messages(page)) if wants_json?
            r.halt 204 if page.empty?
            view = ui(page: page)
            fingerprint = JSON.generate([@user.id, page.messages, page.boosts, page.attachments, db[:users].max(:updated_at)])
            conditional_html(view.page("messages/index", messages: view.context.page_messages(page), layout: false), fingerprint: fingerprint)
          end
          r.post(true) do
            message = service.post_message(@user, @room.id, message_attributes)
            response["location"] = "/rooms/#{@room.id}/messages/#{message[:id]}"
            if @bot
              response["location"] = "#{r.base_url}/messages/#{message[:id]}"
              r.halt 201
            elsif wants_json?
              json(api_messages(repo.present([message])).first, status: 201)
            end
            if wants_stream?
              view = ui(page: repo.present([message]))
              r.halt stream("append", "messages_room_#{@room.id}", view.render(view.context.message(message[:id])))
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
            r.halt 404 if @bot
            page = repo.present([message])
            json(api_messages(page).first) if wants_json?
            view = ui(page: page)
            view.page("messages/show", message: view.context.message(id))
          end
          r.patch(true) { update_message(id) }
          r.put(true) { update_message(id) }
          r.delete(true) do
            service.delete_message(@user, @room.id, id)
            r.halt 204 if wants_json?
            r.halt stream("remove", "message_#{message[:client_message_id]}") if wants_stream?
            r.redirect "/rooms/#{@room.id}"
          end
        end
        r.get "edit" do
          r.halt 404 if @bot
          service.administer!(@user, message)
          view = ui(page: repo.present([message]))
          view.page("messages/edit", message: view.context.message(id), room: view.context.room(@room.id))
        end
        r.on "boosts" do
          r.get "new" do
            r.halt 404 if @bot
            view = ui(page: repo.present([message]))
            view.page("messages/boosts/new", message: view.context.message(id))
          end
          r.is do
            r.get(true) do
              r.halt 404 if @bot
              page = repo.present([message])
              if wants_json?
                view = ui(page: page)
                api = API.new(view)
                json(view.context.message(id).boosts.map { |boost| api.boost(boost) })
              end
              view = ui(page: page)
              view.page("messages/boosts/index", message: view.context.message(id))
            end
            r.post(true) do
              content = (r.params["boost"] || r.params)["content"]
              if @bot
                r.body.rewind
                content = r.body.read(65)
              end
              id = service.boost(@user, @room.id, message[:id], content)
              if wants_json?
                view = ui(page: repo.present([message]))
                json(API.new(view).boost(view.context.message(message[:id]).boosts.find { |boost| boost.id == id }), status: 201)
              end
              r.redirect "/messages/#{message[:id]}/boosts"
            end
          end
          r.delete(Integer) do |boost_id|
            service.unboost(@user, @room.id, id, boost_id)
            r.halt stream("remove", "boost_#{boost_id}") if wants_stream?
            r.halt 204
          end
        end
      end

      def update_message(id)
        message = service.edit_message(@user, @room.id, id, message_attributes)
        json(api_messages(repo.present([message])).first) if wants_json?
        request.redirect "/rooms/#{@room.id}/messages/#{id}"
      end

      def events
        since = [repo.integer(request.params.fetch("after", "0")), 0].max
        rows = db[:events].where(room_id: @room.id).where { id > since }.order(:id).limit(100).all
        changed = rows.reject { |e| e[:kind] == "delete" }.map { |e| e[:message_id] }.uniq
        page = repo.present(db[:messages].where(room_id: @room.id, id: changed).order(:created_at, :id).all)
        view = ui(page: page)
        json({cursor: rows.last&.fetch(:id) || since, more: rows.length == 100,
          deleted: rows.select { |e| e[:kind] == "delete" }.map { |e| e[:message_id] },
          html: view.render(partial: "messages/message", collection: view.context.page_messages(page))})
      end
    end
  end
end
