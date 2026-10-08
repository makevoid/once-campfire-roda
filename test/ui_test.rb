# frozen_string_literal: true
require_relative "test_helper"
require_relative "../lib/campfire/ui/view"
require_relative "../lib/campfire/sound"

class UITest < CampfireTest
  def test_complete_room_frontend_renders_with_independent_erubi_helpers
    message = post_message(admin, room, "<b>Hello</b>")
    service.boost(member, room.id, message[:id], "👍")
    page = repo.messages(room.id)
    view = Campfire::UI::View.new(container: container, actor: admin,
      request: Rack::Request.new(Rack::MockRequest.env_for("http://example.org/rooms/#{room.id}")), csrf: "test-csrf", nonce: "test-nonce", page: page)
    html = view.page("rooms/show", room: view.context.room(room.id), messages: view.context.page_messages(page))
    document = Nokogiri::HTML5(html)
    assert_equal "Watercooler", document.at_css("title").text
    assert_equal 1, document.css("[data-message-id='#{message[:id]}']").length
    assert_equal 8, document.css(".quick-boosts form").length
    assert_equal "<b>Hello</b>", document.at_css("[data-reply-target=body] .lexxy-content").inner_html.strip
    assert document.at_css("lexxy-editor[name='message[body]']")
    assert document.at_css("turbo-cable-stream-source[channel=RoomMessagesChannel]")
    assert_nil document.at_css("script[type=importmap]")["nonce"]
    document.css("script[type=importmap], script[type=module]").each do |script|
      digest = Base64.strict_encode64(Digest::SHA256.digest(script.text))
      assert_includes Campfire::UI::Assets::SCRIPT_HASHES, "\'sha256-#{digest}\'"
    end
    assert document.css("link[rel=stylesheet]").length > 20
    assert document.at_css(".boost[data-boost-delete-booster-id-value='#{member.id}']")
    refute_includes html, "&lt;form"
  end
end
