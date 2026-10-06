# frozen_string_literal: true
require_relative "test_helper"

class RealtimeTest < CampfireTest
  def connection(user)
    token = container.auth.start(user, ip: "127.0.0.1", agent: "protocol-test")
    packets = []
    protocol = Campfire::Realtime::Protocol.new(container: container, token: token,
      request: Rack::Request.new(Rack::MockRequest.env_for("http://example.org/cable")), csrf: "test",
      emit: ->(packet) { packets << JSON.parse(packet) }, close: -> {})
    protocol.start
    (@protocols ||= []) << protocol
    [protocol, packets, token]
  end

  def teardown
    @protocols&.each(&:cleanup)
    super
  end

  def subscribe(protocol, channel, **params)
    identifier = JSON.generate({channel: channel}.merge(params))
    protocol.receive(JSON.generate(command: "subscribe", identifier: identifier))
    identifier
  end

  def test_signed_room_stream_is_membership_checked_and_cannot_use_generic_channel
    private_room = service.create_room(admin, {"name" => "Private"}, type: "Rooms::Closed", user_ids: [member.id])
    signed = container.tokens.generate("room:#{private_room.id}:messages", purpose: :stream)
    protocol, packets = connection(member)
    subscribe(protocol, "RoomMessagesChannel", signed_stream_name: signed)
    assert_equal "confirm_subscription", packets.last["type"]
    subscribe(protocol, "Turbo::StreamsChannel", signed_stream_name: signed)
    assert_equal "reject_subscription", packets.last["type"]
    other, rejected = connection(outsider)
    subscribe(other, "RoomMessagesChannel", signed_stream_name: signed)
    assert_equal "reject_subscription", rejected.last["type"]
    subscribe(protocol, "RoomMessagesChannel", signed_stream_name: signed + "tamper")
    assert_equal "reject_subscription", packets.last["type"]
    db[:memberships].where(room_id: private_room.id, user_id: member.id).delete
    protocol.tick
    assert protocol.closed
    assert_equal "disconnect", packets.last["type"]
    assert_equal true, packets.last["reconnect"]
  end

  def test_messages_edits_boosts_and_deletes_have_correct_turbo_targets
    protocol, packets = connection(member)
    signed = container.tokens.generate("room:#{room.id}:messages", purpose: :stream)
    subscribe(protocol, "RoomMessagesChannel", signed_stream_name: signed)
    message = post_message(admin, room, "hello", client_message_id: "live-one")
    protocol.deliver(:message, db[:events].order(:id).last)
    stream = Nokogiri::HTML5.fragment(packets.last["message"]).at_css("turbo-stream")
    assert_equal "messages_room_#{room.id}", stream["target"]
    assert stream.at_css("#message_live-one")
    service.edit_message(admin, room.id, message[:id], {"body" => "edited"})
    protocol.deliver(:message, db[:events].order(:id).last)
    assert_includes packets.last["message"], 'target="presentation_message_live-one"'
    boost_id = service.boost(member, room.id, message[:id], "👍")
    protocol.deliver(:message, db[:events].order(:id).last)
    assert_includes packets.last["message"], 'target="boosts_message_live-one"'
    service.unboost(member, room.id, message[:id], boost_id)
    protocol.deliver(:message, db[:events].order(:id).last)
    assert_includes packets.last["message"], %(target="boost_#{boost_id}")
    service.delete_message(admin, room.id, message[:id])
    protocol.deliver(:message, db[:events].order(:id).last)
    assert_includes packets.last["message"], 'action="remove" target="message_live-one"'
  end

  def test_presence_counts_tabs_and_session_revocation_disconnects
    first, packets, token = connection(member)
    second, = connection(member)
    subscribe(first, "PresenceChannel", room_id: room.id)
    second_id = subscribe(second, "PresenceChannel", room_id: room.id)
    assert_equal 2, db[:memberships][room_id: room.id, user_id: member.id][:connections]
    second.receive(JSON.generate(command: "message", identifier: second_id, data: JSON.generate(action: "absent")))
    assert_equal 1, db[:memberships][room_id: room.id, user_id: member.id][:connections]
    second.cleanup
    assert_equal 1, db[:memberships][room_id: room.id, user_id: member.id][:connections]
    container.auth.terminate(token)
    first.tick
    assert first.closed
    membership = db[:memberships][room_id: room.id, user_id: member.id]
    assert_equal 0, membership[:connections]
    assert_nil membership[:connected_at]
    assert_equal false, packets.last["reconnect"]
  end

  def test_typing_and_read_unread_events_do_not_escape_their_room_or_user
    private_room = service.create_room(admin, {"name" => "Private"}, type: "Rooms::Closed", user_ids: [member.id])
    protocol, packets = connection(member)
    stranger, stranger_packets = connection(outsider)
    sender, = connection(admin)
    subscribe(protocol, "TypingNotificationsChannel", room_id: private_room.id)
    identifier = subscribe(sender, "TypingNotificationsChannel", room_id: private_room.id)
    subscribe(stranger, "TypingNotificationsChannel", room_id: private_room.id)
    assert_equal "reject_subscription", stranger_packets.last["type"]
    sender.receive(JSON.generate(command: "message", identifier: identifier, data: JSON.generate(action: "start")))
    event = db[:broadcasts].order(:id).last
    protocol.deliver(:broadcast, event)
    stranger.deliver(:broadcast, event)
    assert_equal({"action" => "start", "user" => {"id" => admin.id, "name" => "Admin"}}, packets.last["message"])
    refute stranger_packets.any? { |packet| packet["message"].is_a?(Hash) }
    subscribe(protocol, "UnreadRoomsChannel", user_id: outsider.id)
    subscribe(stranger, "UnreadRoomsChannel", user_id: member.id)
    post_message(admin, private_room, "private")
    event = db[:events].order(:id).last
    protocol.deliver(:message, event)
    stranger.deliver(:message, event)
    assert_equal({"roomId" => private_room.id}, packets.last["message"])
    refute stranger_packets.any? { |packet| packet["message"].is_a?(Hash) }
  end
end
