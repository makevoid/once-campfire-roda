# frozen_string_literal: true
require_relative "test_helper"
require "stringio"

class ResponseCacheTest < CampfireTest
  def database_path = File.join(@directory, "cache.sqlite3")

  def test_cached_gzip_and_identity_preserve_complete_output_and_csp
    post_message(admin, room, "fresh coffee")
    sign_in
    get "/rooms/#{room.id}"
    identity = last_response.body
    csp = last_response["content-security-policy"]
    header "Accept-Encoding", "gzip"
    2.times do
      get "/rooms/#{room.id}"
      assert_equal 200, last_response.status
      assert_equal "gzip", last_response["content-encoding"]
      assert_equal identity, Zlib::GzipReader.new(StringIO.new(last_response.body)).read
      assert_equal csp, last_response["content-security-policy"]
      assert_nil last_response["set-cookie"]
    end
    # A warm hit must not run the presentation query or renderer again.
    repo.stub(:messages, ->(*) { flunk "cached page queried messages" }) do
      get "/rooms/#{room.id}"
      assert_equal 200, last_response.status
    end
    refute_includes identity, 'name="authenticity_token"'
    refute_includes identity, 'name="csrf-token"'
  end

  def test_external_commit_invalidates_and_rollback_does_not
    message = post_message(admin, room, "original coffee")
    sign_in
    get "/rooms/#{room.id}"
    cache = container.response_cache
    version = cache.version
    writer = SQLite3::Database.new(database_path)
    writer.execute("BEGIN IMMEDIATE")
    writer.execute("UPDATE messages SET body='rolled back' WHERE id=?", message[:id])
    writer.execute("ROLLBACK")
    assert_equal version, cache.version
    writer.execute("UPDATE messages SET body='external commit', plain_text='external commit' WHERE id=?", message[:id])
    refute_equal version, cache.version
    get "/rooms/#{room.id}"
    assert_includes last_response.body, "external commit"
    refute_includes last_response.body, "original coffee"
  ensure
    writer&.close
  end

  def test_room_cache_keeps_navigation_side_effects_when_client_ignores_new_cookies
    get "/session/new"
    post "/session", {email_address: admin[:email_address], password: PASSWORD}
    original_cookie = last_response["set-cookie"].split(";").first
    header "Cookie", original_cookie
    header "Accept-Encoding", "gzip"
    get "/rooms/#{room.id}"
    first_body = last_response.body
    assert_equal "gzip", last_response["content-encoding"]
    repo.stub(:messages, ->(*) { flunk "same login cookie missed room cache" }) do
      get "/rooms/#{room.id}"
      assert_equal first_body, last_response.body
      assert last_response["set-cookie"]
    end
  end

  def test_cache_does_not_bypass_session_expiry_revocation_or_room_membership
    private_room = service.create_room(admin, {"name" => "Secret"}, type: "Rooms::Closed", user_ids: [member.id])
    sign_in(member)
    2.times { get "/rooms/#{private_room.id}"; assert_equal 200, last_response.status }
    db[:memberships].where(room_id: private_room.id, user_id: member.id).delete
    get "/rooms/#{private_room.id}"
    assert_equal 404, last_response.status
    2.times { get "/rooms/#{room.id}"; assert_equal 200, last_response.status }
    db[:sessions].update(created_at: Time.now.utc - Campfire::Authentication::SESSION_TTL - 1)
    get "/rooms/#{room.id}"
    assert_equal 302, last_response.status
    sign_in(member)
    get "/rooms/#{room.id}"
    db[:sessions].delete
    get "/rooms/#{room.id}"
    assert_equal 302, last_response.status
  end

  def test_cache_partitions_users_queries_origins_and_accept_encoding
    post_message(admin, room, "coffee")
    post_message(member, room, "tea")
    sign_in
    get "/searches?q=coffee"
    assert_equal 1, Nokogiri::HTML5(last_response.body).css("[data-message-id]").length
    get "/searches?q=tea"
    assert_equal 1, Nokogiri::HTML5(last_response.body).css("[data-message-id]").length
    assert_includes last_response.body, ">tea<"
    header "Host", "chat.example:4567"
    get "/rooms/#{room.id}"
    assert_includes last_response.body, "http://chat.example:4567/rooms/"
    header "Accept-Encoding", "gzip;q=0, identity;q=1"
    get "/rooms/#{room.id}"
    assert_nil last_response["content-encoding"]
    header "Host", nil
    sign_in(member)
    get "/rooms/#{room.id}"
    assert_equal member.id.to_s, Nokogiri::HTML5(last_response.body).at_css('meta[name="current-user-id"]')["content"]
  end

  def test_admission_rechecks_snapshot_and_budgets_entries
    cache = Campfire::ResponseCache.new(db, megabytes: 1)
    entry = ->(body) { {body: body.freeze, headers: {"content-type" => "text/html"}.freeze}.freeze }
    version = cache.version
    cache.write("first", version, entry.call("a" * 600_000))
    cache.write("second", version, entry.call("b" * 600_000))
    assert_nil cache.read("first", version)
    assert cache.read("second", version)
    cache.write("oversized", version, entry.call("c" * 1_048_576))
    assert_nil cache.read("oversized", version)
    db[:accounts].update(name: "Changed")
    cache.write("stale", version, entry.call("old page"))
    assert_nil cache.read("stale", cache.version)
    cache.clear
    refute_equal version, cache.version
  ensure
    cache&.clear
  end

  def test_cached_session_expires_without_a_database_commit_and_snapshots_are_isolated
    token = container.auth.start(member, ip: "127.0.0.1", agent: "snapshot")
    cache = container.response_cache
    version = cache.version
    container.auth.resume(token, cache: cache, version: version)
    first = container.auth.resume(token, cache: cache, version: version)
    first[:name].replace("not shared")
    second = container.auth.resume(token, cache: cache, version: version)
    assert_equal member[:name], second[:name]
    later = Time.now.utc + Campfire::Authentication::SESSION_TTL + 1
    Time.stub(:now, later) { assert_nil container.auth.resume(token, cache: cache, version: version) }
    assert_equal version, cache.version
    db[:users].where(id: member.id).update(status: 2)
    assert_nil container.auth.resume(token, cache: cache, version: version)
  end

  def test_transaction_reads_never_reuse_or_admit_snapshots
    cache = container.response_cache
    version = cache.version
    original = cache.record("account", version) { db[:accounts].first }
    db.transaction(rollback: :always) do
      db[:accounts].update(name: "Uncommitted")
      assert_equal "Uncommitted", cache.record("account", version) { db[:accounts].first }[:name]
    end
    assert_equal original, cache.record("account", version) { flunk "rollback evicted committed snapshot" }
  end
end
