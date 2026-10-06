# frozen_string_literal: true
require_relative "test_helper"

class APITest < CampfireTest
  def test_json_message_schema_and_bot_raw_body_pagination_and_key_rotation
    bot = service.create_user({"name" => "API bot"}, role: 2)
    path = "/rooms/#{room.id}/#{bot.id}-#{bot[:bot_token]}/messages"
    post path, '<p>Hello <strong>API</strong></p>', {"CONTENT_TYPE" => "text/html"}
    assert_equal 201, last_response.status
    assert_empty last_response.body
    id = db[:messages].max(:id)
    assert_equal "http://example.org/messages/#{id}", last_response["location"]
    get path
    assert_equal "1", last_response["x-total-count"]
    row = JSON.parse(last_response.body).first
    assert_equal %w[body created_at creator id room url], row.keys.sort
    assert_equal %w[avatar_url id name role], row["creator"].keys.sort
    assert_equal "bot", row["creator"]["role"]
    assert_equal "Hello API", row.dig("body", "plain_text")
    assert_equal "Hello API", Nokogiri::HTML5.fragment(row.dig("body", "html")).at_css(".lexxy-content").text
    assert_match(/\.\d{3}Z\z/, row["created_at"])
    get "#{path}/#{id}"
    assert_equal 404, last_response.status
    post "#{path}/#{id}/boosts", "👍", {"CONTENT_TYPE" => "text/plain"}
    assert_equal 201, last_response.status
    boost = JSON.parse(last_response.body)
    assert_equal %w[booster content created_at id message], boost.keys.sort
    assert_equal id, boost.dig("message", "id")
    sign_in
    get "/rooms/#{room.id}/messages/#{id}.json"
    assert_equal row, JSON.parse(last_response.body)
    mutate(:put, "/account/bots/#{bot.id}/key")
    assert_equal 302, last_response.status
    refute_equal bot[:bot_token], repo.user(bot.id)[:bot_token]
    get path
    assert_equal 401, last_response.status
  end

  def test_original_push_subscription_form_and_device_management
    sign_in(member)
    params = {endpoint: "https://fcm.googleapis.com/device", p256dh_key: Base64.urlsafe_encode64("x" * 65), auth_key: Base64.urlsafe_encode64("y" * 16)}
    mutate(:post, "/users/me/push_subscriptions", {push_subscription: params})
    assert_equal 200, last_response.status
    id = db[:push_subscriptions].get(:id)
    get "/users/me/push_subscriptions"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "/users/me/push_subscriptions/#{id}/test_notifications"
    mutate(:post, "/users/me/push_subscriptions/#{id}/test_notifications")
    assert_equal 302, last_response.status
    assert_equal({"subscription_id" => id}, JSON.parse(db[:jobs].where(kind: "push_test").get(:payload)))
    sign_in(outsider)
    mutate(:post, "/users/me/push_subscriptions/#{id}/test_notifications")
    assert_equal 404, last_response.status
    sign_in(member)
    mutate(:delete, "/users/me/push_subscriptions/#{id}")
    assert_equal 302, last_response.status
    assert_empty db[:push_subscriptions].all
  end

  def test_push_policy_validates_provider_host_port_and_dns
    valid = "https://updates.push.services.mozilla.com/wpush/v2/test"
    assert_equal "updates.push.services.mozilla.com", Campfire::PushPolicy.validate!(valid, resolver: ->(*) { ["8.8.8.8"] }).hostname
    ["https://fcm.googleapis.com.evil.test/x", "https://example.com/x", "http://fcm.googleapis.com/x", "https://fcm.googleapis.com:8443/x"].each do |url|
      assert_raises(Campfire::Error) { Campfire::PushPolicy.validate!(url, resolve: false) }
    end
    assert_raises(Campfire::Error) { Campfire::PushPolicy.validate!(valid, resolver: ->(*) { ["127.0.0.1"] }) }
    assert_raises(Campfire::Error) { Campfire::PushPolicy.validate!(valid, resolver: ->(*) { [] }) }
  end

  def test_room_update_uses_put_and_home_remembers_last_authorized_room
    second = service.create_room(admin, {"name" => "Second"}, type: "Rooms::Closed", user_ids: [member.id])
    sign_in
    mutate(:put, "/rooms/closeds/#{second.id}", {room: {name: "Updated"}, user_ids: [member.id]})
    assert_equal 302, last_response.status
    get "/rooms/#{second.id}"
    get "/"
    assert_equal "/rooms/#{second.id}", last_response["location"]
    sign_in(member)
    get "/rooms/#{second.id}"
    db[:memberships].where(user_id: member.id, room_id: second.id).delete
    get "/"
    assert_equal "/rooms/#{room.id}", last_response["location"]
    db[:memberships].where(user_id: member.id).delete
    get "/"
    assert_equal 200, last_response.status
    assert Nokogiri::HTML5(last_response.body).at_css(".message-area--empty")
  end
end
