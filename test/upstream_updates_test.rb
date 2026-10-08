# frozen_string_literal: true
require_relative "test_helper"

class UpstreamUpdatesTest < CampfireTest
  def test_unfurl_deadline_also_bounds_dns_before_any_http_request
    original_timeout = Timeout.method(:timeout)
    lookup = ->(*) { sleep 5; ["8.8.8.8"] }
    unfurl = Campfire::OpenGraph.new(resolver: lookup, transport: ->(*) { flunk "DNS should time out first" })
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Timeout.stub(:timeout, ->(_seconds, &block) { original_timeout.call(0.01, &block) }) do
      assert_nil unfurl.from_url("https://example.com/article")
    end
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
  end

  def test_refresh_finds_old_messages_edited_after_the_cursor_through_the_update_index
    old = post_message(admin, room, "old message")
    db[:messages].where(id: old[:id]).update(created_at: Time.now.utc - 86_400)
    cursor = (Time.now.to_f * 1000).floor
    service.edit_message(admin, room.id, old[:id], {"body" => "edited old message"})
    sign_in
    get "/rooms/#{room.id}/refresh?since=#{cursor}"
    assert_equal 200, last_response.status
    document = Nokogiri::HTML5.fragment(last_response.body)
    assert document.at_css(%(turbo-stream[action="replace"][target="message_#{old[:id]}"]))
    assert_includes document.text, "edited old message"
  end

  def test_messages_search_counts_unread_and_jobs_commit_or_rollback_together
    db.run("CREATE TRIGGER reject_delivery BEFORE INSERT ON jobs BEGIN SELECT RAISE(ABORT, 'unavailable'); END")
    assert_raises(Sequel::DatabaseError) { post_message(admin, room, "rollback coffee") }
    assert_equal 0, db[:messages].count
    assert_equal 0, db[:message_search_index].count
    assert_equal 0, db[:rooms][id: room.id][:messages_count]
    assert_nil db[:memberships][room_id: room.id, user_id: member.id][:unread_at]
    assert_equal 0, db[:events].count
    db.run("DROP TRIGGER reject_delivery")
    message = post_message
    assert_equal 1, db[:rooms][id: room.id][:messages_count]
    moved = service.create_room(admin, {"name" => "Destination"}, type: "Rooms::Open")
    db[:messages].where(id: message[:id]).update(room_id: moved.id)
    assert_equal 0, db[:rooms][id: room.id][:messages_count]
    assert_equal 1, db[:rooms][id: moved.id][:messages_count]
    db[:messages].where(id: message[:id]).delete
    assert_equal 0, db[:rooms][id: moved.id][:messages_count]
    assert_equal 0, db[:message_search_index].count
  end

  def test_already_unread_shared_memberships_are_unchanged_but_directs_advance
    post_message
    first = db[:memberships][room_id: room.id, user_id: member.id]
    post_message
    assert_equal first, db[:memberships][id: first[:id]]
    direct = service.create_room(admin, {}, type: "Rooms::Direct", user_ids: [member.id])
    post_message(admin, direct)
    before = db[:memberships][room_id: direct.id, user_id: member.id][:unread_at]
    post_message(admin, direct)
    assert_operator db[:memberships][room_id: direct.id, user_id: member.id][:unread_at], :>, before
  end

  def test_reused_client_message_ids_cannot_displace_another_members_message
    first = post_message(admin, room, "first", client_message_id: "same-client-id")
    second = post_message(member, room, "second", client_message_id: "same-client-id")
    sign_in
    document = Nokogiri::HTML5(last_response.body)
    [first, second].each do |message|
      node = document.at_css("#message_#{message[:id]}")
      assert node
      assert_equal "same-client-id", node["data-client-message-id"]
      refute node.key?("data-pending-message")
    end
    assert_equal 2, document.css('[data-message-id]').length
    assert document.at_css('script[data-messages-target="template"]').text.include?("data-pending-message")
  end

  def test_account_pagination_separates_administrators_and_retains_banned_filter
    now = Time.now.utc
    db[:users].multi_insert(501.times.map do |i|
      {name: "Person %04d" % i, email_address: "person#{i}@example.com", role: 0, status: i == 500 ? 2 : 0, created_at: now, updated_at: now}
    end)
    sign_in
    get "/account/edit"
    document = Nokogiri::HTML5(last_response.body)
    assert_includes document.text, "Admin"
    refute_includes document.text, "Person 0500"
    get "/account/users?page=2"
    assert_includes last_response.body, "Person 0500"
    refute_includes last_response.body, "admin@example.com"
    sign_in(member)
    get "/account/users?page=2"
    refute_includes last_response.body, "Person 0500"
  end

  def test_banning_retains_devices_but_filters_delivery_and_unbanning_restores_it
    id = service.subscribe(member, {"endpoint" => "https://fcm.googleapis.com/device", "keys" => {"p256dh" => Base64.urlsafe_encode64("x" * 65), "auth" => Base64.urlsafe_encode64("y" * 16)}}, agent: "Test")
    service.manage_user(admin, member.id, :ban)
    assert db[:push_subscriptions][id: id]
    delivery = Campfire::Delivery.new(container)
    message = post_message(admin, room, "#{mention(member)} hello")
    delivery.fanout(message[:id])
    assert_equal 0, db[:jobs].where(kind: "push").count
    service.manage_user(admin, member.id, :unban)
    delivery.fanout(message[:id])
    assert_equal 1, db[:jobs].where(kind: "push").count
  end

  def test_unreadable_attachment_is_downloadable_without_preview_retries
    Tempfile.create(["broken", ".png"]) do |file|
      file.binmode
      file.write("\x89PNG\r\n\x1a\ninvalid".b)
      file.flush
      message = post_message(admin, room, "", attachment: {tempfile: file, filename: "broken.png"})
      attachment = db[:attachments][message_id: message[:id]]
      assert_equal "broken.png", message[:plain_text]
      assert_nil container.media.existing_variant(attachment, :thumb)
      container.media.stub(:variant, ->(*) { flunk "view retried failed preview" }) do
        sign_in
        refute Nokogiri::HTML5(last_response.body).at_css("img.message__attachment")
        get "/attachments/#{attachment[:id]}?variant=thumb"
        assert_equal 404, last_response.status
        get "/attachments/#{attachment[:id]}"
        assert_equal 200, last_response.status
        assert_equal File.binread(file.path), last_response.body
      end
    end
  end
end
