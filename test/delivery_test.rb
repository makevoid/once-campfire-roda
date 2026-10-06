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
    message = post_message(admin, room, "@Helper coffee please")
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
    message = post_message(admin, room, "@Helper hello")
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
    attrs = {"endpoint" => "https://push.example.com/device", "keys" => {"p256dh" => Base64.urlsafe_encode64("x" * 65), "auth" => Base64.urlsafe_encode64("y" * 16)}}
    id = service.subscribe(member, attrs, agent: "Test")
    assert_equal id, service.subscribe(member, attrs, agent: "Test again")
    assert_raises(Campfire::Error) { service.subscribe(outsider, attrs, agent: "Other") }
    delivery = Campfire::Delivery.new(container)
    post_message(admin, room, "@Member coffee")
    delivery.work_once
    assert_equal 1, db[:jobs].where(kind: "push").count
    db[:jobs].delete
    service.heartbeat(member, room.id)
    post_message(admin, room, "@Member more coffee")
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
end
