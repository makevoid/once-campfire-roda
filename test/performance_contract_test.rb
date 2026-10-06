# frozen_string_literal: true
require_relative "test_helper"

class PerformanceContractTest < CampfireTest
  def test_timestamp_fast_path_preserves_microseconds_and_offsets
    now = Time.utc(2026, 10, 4, 12, 30, 15, 123456)
    db[:users].where(id: admin.id).update(updated_at: now)
    assert_equal now, db[:users][id: admin.id][:updated_at]
    db.run("UPDATE users SET updated_at = '2026-10-04 14:30:15.123456+02:00' WHERE id = #{admin.id}")
    assert_equal now, db[:users][id: admin.id][:updated_at]
  end

  def test_presentation_query_count_does_not_grow_with_page_size
    counts = []
    logger = Object.new
    logger.define_singleton_method(:info) { |*| counts << true }
    post_message
    db.loggers << logger
    repo.messages(room.id)
    single = counts.length
    db.loggers.clear
    45.times { post_message }
    counts.clear
    db.loggers << logger
    page = repo.messages(room.id)
    assert_equal 40, page.messages.length
    assert_equal single, counts.length
    assert_equal 3, counts.length
  ensure
    db.loggers.clear
  end

  def test_message_pagination_uses_room_timestamp_index
    plan = db.fetch("EXPLAIN QUERY PLAN SELECT id FROM messages WHERE room_id = ? AND (created_at, id) < (?, ?) ORDER BY created_at DESC, id DESC LIMIT 40", room.id, Time.now.utc, 100).all
    assert plan.any? { |row| row[:detail].include?("messages_room_id_created_at_id_index") }, plan.inspect
    refute plan.any? { |row| row[:detail].include?("TEMP B-TREE") }, plan.inspect
  end

  def test_file_database_serializes_concurrent_writes_and_direct_room_creation
    file_db = Campfire::Database.connect(path: File.join(@directory, "concurrent.sqlite3"))
    Campfire::Database.migrate(file_db)
    c = Campfire::Container.new(db: file_db, upload_root: File.join(@directory, "concurrent-files"))
    now = Time.now.utc
    file_db[:accounts].insert(name: "Concurrency", join_code: "test", created_at: now, updated_at: now)
    a = c.service.create_user({"name" => "A", "email_address" => "a@example.com"}, role: 1, digest: DIGEST)
    b = c.service.create_user({"name" => "B", "email_address" => "b@example.com"}, digest: DIGEST)
    threads = 5.times.map do
      Thread.new do
        target = c.service.create_room(a, {}, type: "Rooms::Direct", user_ids: [b.id])
        10.times { c.service.post_message(a, target.id, {"body" => "Concurrent coffee"}) }
        target.id
      end
    end
    assert_equal 1, threads.map(&:value).uniq.length
    assert_equal 50, file_db[:messages].count
    assert_equal 50, file_db[:message_search_index].count
    assert_equal 50, file_db[:events].count
    assert_equal 2, file_db[:memberships].count
  ensure
    file_db&.disconnect
  end
end
