# frozen_string_literal: true
require_relative "test_helper"

class AppTest < CampfireTest
  def test_health_setup_and_login
    get "/up"
    assert_equal "OK", last_response.body
    get "/rooms/#{room.id}"
    assert_equal 302, last_response.status
    sign_in
    assert_includes last_response.body, "Watercooler"
    assert_includes last_response.headers["content-security-policy"], "script-src 'self'"
    mutate(:delete, "/session")
    get "/rooms/#{room.id}"
    assert_equal 302, last_response.status
  end

  def test_setup_is_atomic_and_only_runs_once
    db[:rooms].delete
    db[:users].delete
    db[:accounts].delete
    get "/first_run"
    token = csrf_from_response
    post "/first_run", {authenticity_token: token, user: {name: "First", email_address: "first@example.com", password: PASSWORD}}
    assert_equal 302, last_response.status
    assert_equal 1, db[:accounts].count
    assert_equal 1, db[:users].where(role: 1).count
    assert_equal 1, db[:memberships].count
    get "/first_run"
    assert_equal 302, last_response.status
  end

  def test_csrf_is_required_and_rotated_at_login
    get "/session/new"
    old = csrf_from_response
    post "/session", {email_address: admin[:email_address], password: PASSWORD}
    assert_equal 403, last_response.status
    sign_in
    refute_equal old, @csrf
    mutate(:post, "/rooms/#{room.id}/messages", {message: {body: "Oops"}}, csrf: false)
    assert_equal 403, last_response.status
    assert_equal 0, db[:messages].count
  end

  def test_revoked_sessions_and_deactivated_accounts_stop_working
    sign_in(member)
    service.manage_user(admin, member.id, :deactivate)
    get "/rooms/#{room.id}"
    assert_equal 302, last_response.status
    assert_equal 0, db[:sessions].where(user_id: member.id).count
  end

  def test_message_lifecycle_and_search_index
    sign_in(member)
    header "Accept", "application/json"
    mutate(:post, "/rooms/#{room.id}/messages", {message: {body: "coffee beans"}})
    assert_equal 201, last_response.status, last_response.body
    message = JSON.parse(last_response.body)
    id = message.fetch("id")
    get "/searches?q=coffee"
    assert_equal [id], JSON.parse(last_response.body).map { |row| row["id"] }
    mutate(:patch, "/messages/#{id}", {message: {body: "tea leaves"}})
    assert_equal 200, last_response.status
    get "/searches?q=coffee"
    assert_equal [], JSON.parse(last_response.body)
    mutate(:delete, "/messages/#{id}")
    assert_equal 204, last_response.status
    assert_equal 0, db[:message_search_index].count
    get "/rooms/#{room.id}/events?after=0"
    data = JSON.parse(last_response.body)
    assert_equal [id], data["deleted"]
    assert_equal "", data["html"]
  end

  def test_private_rooms_cursors_search_attachments_and_events_are_scoped
    private_room = service.create_room(admin, {"name" => "Secret"}, type: "Rooms::Closed", user_ids: [member.id])
    secret = post_message(admin, private_room, "secret coffee")
    sign_in(outsider)
    ["/rooms/#{private_room.id}", "/messages/#{secret[:id]}", "/rooms/#{private_room.id}/events", "/rooms/#{room.id}/messages?before=#{secret[:id]}"].each do |path|
      get path
      assert_equal 404, last_response.status, path
    end
    get "/searches?q=coffee"
    refute_includes last_response.body, "secret coffee"
    mutate(:post, "/rooms/#{private_room.id}/messages", {message: {body: "intruder"}})
    assert_equal 404, last_response.status
  end

  def test_only_creator_or_admin_can_change_messages_and_boosts
    original = post_message(member)
    sign_in(outsider)
    mutate(:patch, "/messages/#{original[:id]}", {message: {body: "changed"}})
    assert_equal 403, last_response.status
    mutate(:delete, "/messages/#{original[:id]}")
    assert_equal 403, last_response.status
    header "Accept", "application/json"
    mutate(:post, "/messages/#{original[:id]}/boosts", {content: "☕"})
    assert_equal 201, last_response.status
    boost_id = JSON.parse(last_response.body).fetch("id")
    other_boost = service.boost(member, room.id, original[:id], "yes")
    mutate(:delete, "/messages/#{original[:id]}/boosts/#{other_boost}")
    assert_equal 403, last_response.status
    mutate(:delete, "/messages/#{original[:id]}/boosts/#{boost_id}")
    assert_equal 204, last_response.status
  end

  def test_pagination_is_stable_with_identical_timestamps
    timestamp = Time.utc(2026, 1, 1)
    85.times do |i|
      db[:messages].insert(room_id: room.id, creator_id: admin.id, client_message_id: i.to_s, body: i.to_s, plain_text: i.to_s, created_at: timestamp, updated_at: timestamp)
    end
    latest = repo.messages(room.id).messages
    assert_equal (46..85).to_a, latest.map { |m| m[:id] }
    older = repo.messages(room.id, before: latest.first[:id]).messages
    assert_equal (6..45).to_a, older.map { |m| m[:id] }
    assert_equal (46..85).to_a, repo.messages(room.id, after: 45).messages.map { |m| m[:id] }
    assert_equal 81, repo.messages(room.id, around: 43).messages.length
  end

  def test_only_the_booster_can_remove_a_boost_even_for_administrators
    message = post_message(member)
    boost_id = service.boost(member, room.id, message[:id], "☕")
    sign_in(admin)
    refute_includes last_response.body, %(data-boost-id="#{boost_id}")
    mutate(:delete, "/messages/#{message[:id]}/boosts/#{boost_id}")
    assert_equal 403, last_response.status
    refute_nil db[:boosts][id: boost_id]
    sign_in(member)
    assert_includes last_response.body, %(data-boost-id="#{boost_id}")
    mutate(:delete, "/messages/#{message[:id]}/boosts/#{boost_id}")
    assert_equal 204, last_response.status
    assert_nil db[:boosts][id: boost_id]
  end

  def test_hidden_direct_rooms_do_not_reappear_as_people_suggestions
    20.times { |index| make_user("Suggested#{index}") }
    assert_equal 19, repo.sidebar(admin)[:people].length
    direct = service.create_room(admin, {}, type: "Rooms::Direct", user_ids: [member.id])
    service.involvement(admin, direct.id, "invisible")
    sidebar = repo.sidebar(admin)
    assert_empty sidebar[:direct]
    assert_equal 17, sidebar[:people].length
    refute_includes sidebar[:people].map { |person| person[:id] }, member.id
    assert_includes sidebar[:people].map { |person| person[:id] }, outsider.id
    sign_in
    get "/users/me/sidebar"
    refute_includes last_response.body, %(href="/rooms/#{direct.id}")
    refute_includes last_response.body, %(href="/rooms/directs/new?user_id=#{member.id}")
  end

  def test_unread_and_invisible_membership_semantics
    service.heartbeat(member, room.id)
    post_message
    assert_nil db[:memberships][room_id: room.id, user_id: member.id][:unread_at]
    refute_nil db[:memberships][room_id: room.id, user_id: outsider.id][:unread_at]
    service.heartbeat(outsider, room.id)
    assert_nil db[:memberships][room_id: room.id, user_id: outsider.id][:unread_at]
    service.involvement(outsider, room.id, "invisible")
    assert_empty repo.sidebar(outsider)[:shared]
    assert_raises(Campfire::Error) { service.involvement(outsider, room.id, "anything") }
  end

  def test_direct_rooms_are_unique_and_cannot_be_converted_or_reached_through_other_namespaces
    first = service.create_room(member, {}, type: "Rooms::Direct", user_ids: [outsider.id])
    second = service.create_room(outsider, {}, type: "Rooms::Direct", user_ids: [member.id])
    assert_equal first.id, second.id
    assert_raises(Campfire::Error) { service.update_room(member, first.id, {"name" => "Oops"}, type: "Rooms::Open") }
    sign_in(member)
    get "/rooms/opens/#{first.id}/edit"
    assert_equal 404, last_response.status
    mutate(:delete, "/rooms/directs/#{room.id}")
    assert_equal 404, last_response.status
    assert_equal 2, db[:rooms].count
    mutate(:delete, "/rooms/directs/#{first.id}")
    assert_equal 302, last_response.status
    assert_nil db[:rooms][id: first.id]
  end

  def test_uploads_are_downloaded_with_authorization_and_safe_headers
    file = File.join(@directory, "upload.html")
    File.write(file, "<script>alert(1)</script>")
    private_room = service.create_room(admin, {"name" => "Secret"}, type: "Rooms::Closed")
    sign_in
    upload = Rack::Test::UploadedFile.new(file, "text/html")
    mutate(:post, "/rooms/#{private_room.id}/messages", {message: {body: "", attachment: upload}})
    assert_equal 302, last_response.status, last_response.body
    attachment = db[:attachments].first
    get "/attachments/#{attachment[:id]}"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.headers["content-type"]
    assert_includes last_response.headers["content-disposition"], "attachment"
    assert_equal File.read(file), last_response.body
    sign_in(outsider)
    get "/attachments/#{attachment[:id]}"
    assert_equal 404, last_response.status
  end

  def test_xss_is_sanitized_and_names_and_boosts_are_escaped
    content = Campfire::Content.new('<script>alert(1)</script><img src=x onerror=alert(1)><a href="javascript:alert(1)">bad</a><strong onclick="evil()">coffee</strong><a href="https://example.com">link</a>')
    refute_match(/script|onerror|onclick|javascript/, content.html)
    assert_includes content.html, "<strong>coffee</strong>"
    assert_includes content.html, 'href="https://example.com"'
    message = post_message(admin, room, content.html)
    service.boost(member, room.id, message[:id], "<script>")
    sign_in
    refute_includes last_response.body, "<script>"
    assert_includes last_response.body, "&lt;script&gt;"
  end

  def test_content_accepts_utf8_bytes_but_rejects_invalid_encoding
    assert_equal "☕ coffee", Campfire::Content.new("☕ coffee".b).text
    assert_raises(Campfire::Error) { Campfire::Content.new("\xff".b) }
  end

  def test_retries_are_idempotent_and_index_writes_roll_back
    one = post_message(member, room, "first", client_message_id: "client-1")
    two = post_message(member, room, "retry", client_message_id: "client-1")
    assert_equal one[:id], two[:id]
    assert_equal 1, db[:messages].count
    assert_equal 1, db[:events].count
    db.transaction(rollback: :always) { post_message }
    assert_equal 1, db[:message_search_index].count
  end

  def test_bot_auth_membership_crud_and_rotation
    bot = service.create_user({"name" => "Robot"}, role: 2)
    base = "/rooms/#{room.id}/#{bot.id}-#{bot[:bot_token]}/messages"
    post base, "robot coffee", {"CONTENT_TYPE" => "text/plain"}
    assert_equal 201, last_response.status, last_response.body
    id = JSON.parse(last_response.body)["id"]
    get base
    assert_equal 200, last_response.status
    assert_equal "1", last_response.headers["x-total-count"]
    assert_equal "robot coffee", JSON.parse(last_response.body).first["body"]["plain_text"]
    patch "#{base}/#{id}", "tea", {"CONTENT_TYPE" => "text/plain"}
    assert_equal 200, last_response.status
    delete "#{base}/#{id}"
    assert_equal 204, last_response.status
    db[:memberships].where(user_id: bot.id).delete
    get base
    assert_equal 404, last_response.status
    db[:users].where(id: bot.id).update(bot_token: SecureRandom.hex(24))
    get base
    assert_equal 401, last_response.status
  end

  def test_empty_bot_posts_and_invalid_keys_are_rejected_without_writes
    bot = service.create_user({"name" => "Robot"}, role: 2)
    base = "/rooms/#{room.id}/#{bot.id}-#{bot[:bot_token]}/messages"
    post base, "", {"CONTENT_TYPE" => "text/plain"}
    assert_equal 422, last_response.status
    assert_equal 0, db[:messages].count
  end

  def test_login_throttle_expiry_and_tampered_cookies
    key = Digest::SHA256.hexdigest("test-ip")
    db[:login_attempts].insert(key: key, attempts: 10, window: Time.now.to_i / 180)
    error = assert_raises(Campfire::Error) { container.auth.authenticate(admin[:email_address], PASSWORD, ip: "test-ip") }
    assert_equal 429, error.status
    db[:login_attempts].where(key: key).update(window: Time.now.to_i / 180 - 1)
    assert_equal admin.id, container.auth.authenticate(admin[:email_address], PASSWORD, ip: "test-ip").id
    token = container.auth.start(admin, ip: "test-ip", agent: "Test")
    assert_equal admin.id, container.auth.resume(token).id
    db[:sessions].update(created_at: Time.now.utc - 31 * 86400)
    assert_nil container.auth.resume(token)
    set_cookie "session_token=tampered"
    get "/rooms/#{room.id}"
    assert_equal 302, last_response.status
  end

  def test_sidebar_search_and_conditional_responses
    45.times { |i| post_message(admin, room, "coffee #{i}") }
    sign_in(member)
    get "/users/me/sidebar"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Watercooler"
    etag = last_response.headers["etag"]
    header "If-None-Match", etag
    get "/users/me/sidebar"
    assert_equal 304, last_response.status
    header "If-None-Match", nil
    get "/rooms/#{room.id}/messages?before=44"
    assert_equal 40, last_response.body.scan('class="message"').length
    12.times { |i| service.record_search(member, "coffee #{i}") }
    assert_equal 10, db[:searches].where(user_id: member.id).count
    service.record_search(outsider, "coffee")
    assert_equal 1, db[:searches].where(user_id: outsider.id).count
    ["AND", '"', "coffee OR", "coffee'); DROP TABLE users;--"].each do |query|
      get "/searches", {q: query}
      assert_equal 200, last_response.status, last_response.body
    end
  end

  def test_account_bot_room_and_profile_forms
    sign_in
    %w[/account/edit /account/bots /account/bots/new /rooms/opens/new /rooms/closeds/new /rooms/directs/new /users/me/profile].each do |path|
      get path
      assert_equal 200, last_response.status, path
    end
    mutate(:post, "/account/bots", {user: {name: "Helper"}})
    assert_equal 302, last_response.status
    assert_equal 1, db[:users].where(role: 2).count
    mutate(:post, "/rooms/closeds", {room: {name: "Planning"}, user_ids: [member.id]})
    assert_equal 302, last_response.status
    assert_equal 2, db[:memberships].where(room_id: db[:rooms].max(:id)).count
    mutate(:patch, "/users/me/profile", {user: {name: "New name", bio: "Hello"}})
    assert_equal "New name", db[:users][id: admin.id][:name]
    sign_in(member)
    get "/account/edit"
    assert_equal 403, last_response.status
  end

  def test_last_administrator_is_preserved
    assert_raises(Campfire::Error) { service.manage_user(admin, admin.id, :deactivate) }
    assert_raises(Campfire::Error) { service.manage_user(admin, admin.id, :ban) }
    assert_raises(Campfire::Error) { service.manage_user(admin, admin.id, :role, role: "member") }
  end

  def test_unread_fanout_encodes_once_and_uses_private_streams
    captured = []
    adapter = Object.new
    adapter.define_singleton_method(:broadcast) { |stream, body| captured << [stream, body] }
    Campfire::UnreadFanout.new(adapter).broadcast(room.id, (1..1000).to_a)
    assert_equal 1000, captured.length
    assert_equal 1, captured.map { |_, body| body.object_id }.uniq.length
    assert_equal "unread_rooms:1", captured.first.first
    assert_equal({"roomId" => room.id}, JSON.parse(captured.first.last))
  end
end
