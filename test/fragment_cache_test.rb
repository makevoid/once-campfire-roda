# frozen_string_literal: true
require_relative "test_helper"

class FragmentCacheTest < CampfireTest
  def render_message(id, base: "http://example.org")
    page = repo.present([repo.message(room.id, id)])
    view = Campfire::UI::View.new(container: container, actor: admin,
      request: Rack::Request.new(Rack::MockRequest.env_for("#{base}/rooms/#{room.id}")), csrf: nil, nonce: nil, page: page)
    view.render(view.context.message(id))
  end

  def test_unrelated_writes_keep_content_fragments_but_foreign_edits_and_profiles_invalidate
    message = post_message(admin, room, "original")
    first = render_message(message[:id])
    db[:accounts].update(name: "Unrelated account rename")
    assert_same first, render_message(message[:id])
    # No updated_at touch: content itself must decide whether reuse is safe.
    db[:messages].where(id: message[:id]).update(body: "foreign edit", plain_text: "foreign edit")
    edited = render_message(message[:id])
    refute_same first, edited
    assert_includes edited, "foreign edit"
    db[:users].where(id: admin.id).update(name: "Changed author")
    renamed = render_message(message[:id])
    assert_includes renamed, "Changed author"
    refute_same edited, renamed
    db[:rooms].where(id: room.id).update(name: "Different room")
    assert_includes render_message(message[:id]), "Different room"
  end

  def test_boost_content_booster_profiles_and_request_ports_are_dependencies
    message = post_message
    first = render_message(message[:id])
    boost = service.boost(member, room.id, message[:id], "👍")
    boosted = render_message(message[:id])
    refute_same first, boosted
    assert_includes boosted, "boost_#{boost}"
    db[:boosts].where(id: boost).update(content: "hello")
    db[:users].where(id: member.id).update(name: "New booster")
    changed = render_message(message[:id])
    assert_includes changed, "New booster"
    assert_includes changed, ">hello<"
    port = render_message(message[:id], base: "http://example.org:4567")
    assert_includes port, "http://example.org:4567/rooms/"
    refute_same changed, port
  end

  def test_mention_fragments_are_live_when_mentioned_user_changes
    message = post_message(admin, room, "#{mention(member)} hello")
    first = render_message(message[:id])
    db[:users].where(id: member.id).update(name: "New mention name")
    second = render_message(message[:id])
    refute_equal first, second
    assert_includes second, "New mention name"
  end

  def test_budget_and_disabled_cache_do_not_retain_oversize_output
    cache = Campfire::FragmentCache.new(megabytes: 1)
    cache.fetch("one") { "a" * 600_000 }
    cache.fetch("two") { "b" * 600_000 }
    assert_equal "fresh", cache.fetch("one") { "fresh" }
    cache.fetch("large") { "c" * 1_048_576 }
    assert_equal "uncached", cache.fetch("large") { "uncached" }
    disabled = Campfire::FragmentCache.new(megabytes: 0)
    assert_equal "first", disabled.fetch("key") { "first" }
    assert_equal "second", disabled.fetch("key") { "second" }
  end
end
