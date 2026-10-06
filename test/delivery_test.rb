# frozen_string_literal: true
require_relative "test_helper"

class DeliveryTest < CampfireTest
  def test_queue_claims_once_retries_and_reclaims_abandoned_jobs
    queue = Campfire::JobQueue.new(db)
    queue.enqueue("fanout", {message_id: 1}, key: "one")
    queue.enqueue("fanout", {message_id: 1}, key: "one")
    assert_equal 1, db[:jobs].count
    job = queue.claim
    assert_equal 1, job[:attempts]
    assert_nil queue.claim
    queue.fail(job, RuntimeError.new("sensitive content"))
    assert_equal "RuntimeError", db[:jobs].first[:last_error]
    assert_nil queue.claim
    db[:jobs].update(available_at: Time.now.utc - 1)
    retry_job = queue.claim
    assert_equal 2, retry_job[:attempts]
    queue.finish(job)
    assert_equal 1, db[:jobs].count # An old lease cannot delete a new attempt.
    queue.finish(retry_job)
    assert_equal 0, db[:jobs].count
  end

  def test_webhooks_are_only_queued_for_mentioned_or_direct_bots
    bot = service.create_user({"name" => "Helper"}, role: 2)
    service.update_bot(admin, bot.id, {"name" => "Helper", "webhook_url" => "http://localhost:9000/hook"})
    delivery = Campfire::Delivery.new(container)
    post_message(admin, room, "hello")
    assert delivery.work_once
    assert_equal 0, db[:jobs].count
    message = post_message(admin, room, "#{mention(bot)} coffee please")
    delivery.work_once
    job = db[:jobs].where(kind: "webhook").first
    assert_equal message[:id], JSON.parse(job[:payload])["message_id"]
    db[:memberships].where(room_id: room.id, user_id: bot.id).delete
    http = Object.new
    http.define_singleton_method(:post) { |*| raise "must not deliver after revocation" }
    Campfire::Delivery.new(container, http: http).work_once
    assert_equal 0, db[:jobs].count
  end

  def test_webhook_text_reply_is_sanitized_and_deduplicated
    bot = service.create_user({"name" => "Helper"}, role: 2)
    service.update_bot(admin, bot.id, {"name" => "Helper", "webhook_url" => "https://example.com/hook"})
    message = post_message(admin, room, "#{mention(bot)} hello")
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["content-type"] = "text/html"
    response.body = '<script>evil()</script><b>Hello</b>'
    response.instance_variable_set(:@read, true)
    http = Object.new
    http.define_singleton_method(:post) { |*args, **kwargs| response }
    delivery = Campfire::Delivery.new(container, http: http)
    2.times { delivery.webhook(message[:id], bot.id) }
    replies = db[:messages].where(creator_id: bot.id).all
    assert_equal 1, replies.length
    assert_equal "<b>Hello</b>", replies.first[:body]
  end

  def test_push_fanout_obeys_mentions_presence_and_device_ownership
    attrs = {"endpoint" => "https://fcm.googleapis.com/device", "keys" => {"p256dh" => Base64.urlsafe_encode64("x" * 65), "auth" => Base64.urlsafe_encode64("y" * 16)}}
    id = service.subscribe(member, attrs, agent: "Test")
    assert_equal id, service.subscribe(member, attrs, agent: "Test again")
    assert_raises(Campfire::Error) { service.subscribe(outsider, attrs, agent: "Other") }
    delivery = Campfire::Delivery.new(container)
    post_message(admin, room, "#{mention(member)} coffee")
    delivery.work_once
    assert_equal 1, db[:jobs].where(kind: "push").count
    db[:jobs].delete
    service.heartbeat(member, room.id)
    post_message(admin, room, "#{mention(member)} more coffee")
    delivery.work_once
    assert_equal 0, db[:jobs].count
  end

  def test_push_address_policy_rejects_private_mapped_and_special_addresses
    %w[127.0.0.1 10.0.0.1 169.254.169.254 192.168.1.2 100.64.0.1 ::1 fe80::1 fc00::1 ::ffff:127.0.0.1 2001:db8::1 224.0.0.1].each do |address|
      refute Campfire::OutboundHTTP.public_address?(address), address
    end
    assert Campfire::OutboundHTTP.public_address?("8.8.8.8")
    assert Campfire::OutboundHTTP.public_address?("2606:4700:4700::1111")
    assert_raises(Campfire::Error) { Campfire::OutboundHTTP.uri("file:///etc/passwd") }
    assert_raises(Campfire::Error) { Campfire::OutboundHTTP.uri("https://user:password@example.com") }
    assert_raises(Campfire::Error) { Campfire::OutboundHTTP.uri("http://example.com", https_only: true) }
  end

  def test_webhook_attachment_reply_payload_and_timeout_message
    bot = service.create_user({"name" => "Helper"}, role: 2)
    service.update_bot(admin, bot.id, {"name" => "Helper", "webhook_url" => "http://localhost/hook"})
    message = post_message(admin, room, "#{mention(bot)} hello")
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["content-type"] = "image/png"
    response.body = Vips::Image.black(20, 10).write_to_buffer(".png")
    response.instance_variable_set(:@read, true)
    calls = []
    http = Object.new
    http.define_singleton_method(:post) { |url, **options| calls << options; response }
    delivery = Campfire::Delivery.new(container, http: http)
    delivery.webhook(message[:id], bot.id)
    payload = JSON.parse(calls.first[:body])
    assert_equal "hello", payload.dig("message", "body", "plain")
    assert_equal "/rooms/#{room.id}/#{bot.id}-#{bot[:bot_token]}/messages", payload.dig("room", "path")
    reply = db[:messages].where(creator_id: bot.id).first
    assert_equal "image/png", db[:attachments][message_id: reply[:id]][:content_type]
    http.define_singleton_method(:post) { |*args, **options| raise Net::ReadTimeout }
    message = post_message(admin, room, "#{mention(bot)} again")
    delivery.webhook(message[:id], bot.id)
    assert_equal "Failed to respond within 7 seconds", db[:messages].where(creator_id: bot.id).order(:id).last[:plain_text]
  end

  def test_push_payload_includes_badge_and_room_and_rechecks_membership
    old = ENV.values_at("VAPID_PRIVATE_KEY", "VAPID_PUBLIC_KEY")
    ENV["VAPID_PRIVATE_KEY"] = ENV["VAPID_PUBLIC_KEY"] = "test-key"
    id = service.subscribe(member, {"endpoint" => "https://fcm.googleapis.com/device", "keys" => {"p256dh" => Base64.urlsafe_encode64("x" * 65), "auth" => Base64.urlsafe_encode64("y" * 16)}}, agent: "Test")
    calls = []
    push = Class.new do
      define_method(:initialize) { |**options| calls << options }
      def perform; end
    end
    delivery = Campfire::Delivery.new(container, push_class: push)
    message = post_message(admin, room, "#{mention(member)} hello")
    delivery.push(message[:id], id)
    payload = JSON.parse(calls.first[:message])
    assert_equal "Watercooler", payload["title"]
    assert_equal "Admin: @Member hello", payload.dig("options", "body")
    assert_equal({"path" => "/rooms/#{room.id}", "badge" => 1}, payload.dig("options", "data"))
    assert_equal "high", calls.first[:urgency]
    db[:memberships].where(room_id: room.id, user_id: member.id).delete
    delivery.push(message[:id], id)
    assert_equal 1, calls.length
  ensure
    ENV["VAPID_PRIVATE_KEY"], ENV["VAPID_PUBLIC_KEY"] = old
  end
end
