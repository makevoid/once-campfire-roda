# frozen_string_literal: true

module Campfire
  module Realtime
    # The frontend speaks the documented Action Cable JSON wire protocol. This
    # implementation owns authentication, subscriptions and dispatch independently.
    class Protocol
      Subscription = Struct.new(:channel, :room_id, :stream, :present)
      ROOM_CHANNELS = %w[RoomChannel PresenceChannel TypingNotificationsChannel].freeze
      attr_reader :closed

      def initialize(container:, token:, request:, csrf:, emit:, close:)
        @container, @db, @token, @request, @csrf, @emit, @close = container, container.db, token, request, csrf, emit, close
        @subscriptions, @closed = {}, false
        authorize!
      end

      def start
        transmit(type: "welcome") unless @closed
      end

      def receive(data)
        return if @closed || !authorize!
        packet = JSON.parse(data)
        return unless packet.is_a?(Hash)
        identifier = packet["identifier"]
        return unless identifier.is_a?(String) && identifier.bytesize <= 4096
        case packet["command"]
        when "subscribe" then subscribe(identifier)
        when "unsubscribe" then unsubscribe(identifier)
        when "message" then perform(identifier, JSON.parse(packet.fetch("data", "{}")))
        end
      rescue JSON::ParserError, TypeError, ArgumentError
        disconnect(reconnect: false)
      end

      def tick
        return unless authorize!
        transmit(type: "ping", message: Time.now.to_i)
      end

      def deliver(kind, event)
        return unless authorize!
        return disconnect(reconnect: true) if kind == :overflow
        kind == :message ? deliver_message(event) : deliver_broadcast(event)
      end

      def disconnect(reconnect: false)
        return if @closed
        transmit(type: "disconnect", reason: "unauthorized", reconnect: reconnect)
        cleanup
        @close.call
      end

      def cleanup
        @subscriptions.keys.each { |id| unsubscribe(id) }
        @closed = true
      end

      private

      def authorize!
        return false if @closed
        actor = @container.auth.resume(@token)
        unless actor
          disconnect(reconnect: false)
          return false
        end
        @user = actor
        if @subscriptions.values.any? { |sub| sub.room_id && !membership(sub.room_id) }
          disconnect(reconnect: true)
          return false
        end
        true
      end

      def membership(room_id) = @db[:memberships][room_id: room_id, user_id: @user.id]

      def subscribe(identifier)
        return transmit(type: "confirm_subscription", identifier: identifier) if @subscriptions.key?(identifier)
        return reject(identifier) if @subscriptions.length >= 32
        params = JSON.parse(identifier)
        return reject(identifier) unless params.is_a?(Hash)
        channel = params["channel"]
        room_id = nil
        stream = nil
        if ROOM_CHANNELS.include?(channel)
          room_id = Integer(params["room_id"].to_s, 10)
          return reject(identifier) unless membership(room_id)
        elsif channel == "RoomMessagesChannel"
          stream = @container.tokens.verify(params["signed_stream_name"], purpose: :stream)
          match = /\Aroom:(\d+):messages\z/.match(stream.to_s)
          return reject(identifier) unless match && membership(room_id = match[1].to_i)
        elsif channel == "Turbo::StreamsChannel"
          stream = @container.tokens.verify(params["signed_stream_name"], purpose: :stream)
          return reject(identifier) unless ["rooms", "user:#{@user.id}:rooms"].include?(stream)
        elsif !%w[HeartbeatChannel ReadRoomsChannel UnreadRoomsChannel].include?(channel)
          return reject(identifier)
        end
        subscription = Subscription.new(channel, room_id, stream, false)
        @subscriptions[identifier] = subscription
        presence(subscription, "present") if channel == "PresenceChannel"
        transmit(type: "confirm_subscription", identifier: identifier)
      rescue ArgumentError
        reject(identifier)
      end

      def reject(identifier) = transmit(type: "reject_subscription", identifier: identifier)

      def unsubscribe(identifier)
        subscription = @subscriptions.delete(identifier)
        presence(subscription, "absent") if subscription&.channel == "PresenceChannel"
      end

      def perform(identifier, data)
        sub = @subscriptions[identifier]
        return unless sub && data.is_a?(Hash)
        action = data["action"]
        if sub.channel == "PresenceChannel" && %w[present absent refresh].include?(action)
          presence(sub, action)
        elsif sub.channel == "TypingNotificationsChannel" && %w[start stop].include?(action)
          @container.hub.publish("typing:#{sub.room_id}", action: action, user: {id: @user.id, name: @user[:name]})
        end
      end

      def presence(sub, action)
        @db.transaction(mode: :immediate) do
          row = membership(sub.room_id)
          next unless row
          now = Time.now.utc
          connected = row[:connected_at] && row[:connected_at] >= now - 60
          count = connected ? row[:connections] : 0
          changes = {}
          case action
          when "present"
            count += 1 unless sub.present && connected
            sub.present = true
            changes = {connections: count, connected_at: now, unread_at: nil}
          when "absent"
            next unless sub.present
            count = [count - 1, 0].max
            sub.present = false
            changes = {connections: count, connected_at: count.zero? ? nil : row[:connected_at], updated_at: now}
          when "refresh"
            next unless sub.present
            changes = {connections: [count, 1].max, connected_at: now}
          end
          @db[:memberships].where(id: row[:id]).update(changes)
        end
        @container.hub.publish("read:#{@user.id}", room_id: sub.room_id) if action == "present"
      end

      def view(page: nil)
        UI::View.new(container: @container, actor: @user, request: @request, csrf: @csrf, nonce: "", page: page)
      end

      def deliver_message(event)
        payload = JSON.parse(event[:payload])
        rendered = nil
        @subscriptions.each do |identifier, sub|
          if sub.channel == "RoomMessagesChannel" && sub.room_id == event[:room_id]
            rendered ||= message_stream(event, payload)
            transmit(identifier: identifier, message: rendered) unless rendered.empty?
          elsif sub.channel == "UnreadRoomsChannel" && event[:kind] == "create"
            member = membership(event[:room_id])
            if member && member[:involvement] != "invisible" && member[:unread_at] && payload["creator_id"] != @user.id
              transmit(identifier: identifier, message: {roomId: event[:room_id]})
            end
          end
        end
      end

      def message_stream(event, payload)
        if event[:kind] == "delete"
          return turbo("remove", "message_#{payload['client_message_id']}")
        elsif event[:kind] == "boost_delete"
          return turbo("remove", "boost_#{payload['boost_id']}")
        end
        message = @db[:messages][id: event[:message_id], room_id: event[:room_id]]
        return "" unless message
        ui = view(page: @container.repo.present([message]))
        record = ui.context.message(message[:id])
        case event[:kind]
        when "create" then turbo("append", "messages_room_#{event[:room_id]}", ui.render(record))
        when "edit" then turbo("replace", "presentation_message_#{message[:client_message_id]}", ui.render("messages/presentation", message: record))
        when "boost_create"
          boost = record.boosts.find { |item| item.id == payload["boost_id"] }
          boost ? turbo("append", "boosts_message_#{message[:client_message_id]}", ui.render("messages/boosts/boost", boost: boost)) : ""
        else turbo("replace", "message_#{message[:client_message_id]}", ui.render(record))
        end
      end

      def deliver_broadcast(event)
        data = JSON.parse(event[:payload])
        sidebar = nil
        @subscriptions.each do |identifier, sub|
          if sub.channel == "TypingNotificationsChannel" && event[:stream] == "typing:#{sub.room_id}"
            transmit(identifier: identifier, message: data)
          elsif sub.channel == "ReadRoomsChannel" && event[:stream] == "read:#{@user.id}"
            transmit(identifier: identifier, message: data)
          elsif sub.channel == "Turbo::StreamsChannel" && event[:stream] == "sidebar" && data["users"].include?(@user.id)
            unless sidebar
              ui = view
              assigns = ui.context.sidebar(@container.repo.sidebar(@user))
              sidebar = turbo("replace", "user_sidebar", ui.page("users/sidebars/show", assigns, layout: false))
            end
            transmit(identifier: identifier, message: sidebar)
            break
          end
        end
      end

      def turbo(action, target, html = "")
        %(<turbo-stream action="#{action}" target="#{CGI.escapeHTML(target)}" maintain-scroll="true"><template>#{html}</template></turbo-stream>)
      end

      def transmit(packet) = @emit.call(JSON.generate(packet))
    end
  end
end
