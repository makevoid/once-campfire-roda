# frozen_string_literal: true
require_relative "test_helper"

class FrontendTest < CampfireTest
  def test_message_forms_and_turbo_mutations_use_original_dom_contract
    sign_in
    header "Accept", "text/vnd.turbo-stream.html"
    mutate(:post, "/rooms/#{room.id}/messages", {message: {body: "Hello", client_message_id: "browser-one"}})
    assert_equal 200, last_response.status
    assert_includes last_response.content_type, "turbo-stream"
    stream = Nokogiri::HTML5.fragment(last_response.body).at_css("turbo-stream")
    assert_equal "append", stream["action"]
    assert_equal "messages_room_#{room.id}", stream["target"]
    assert stream.at_css("#message_browser-one")
    id = db[:messages].max(:id)
    header "Accept", "text/html"
    ["/rooms/#{room.id}/messages/#{id}", "/rooms/#{room.id}/messages/#{id}/edit", "/messages/#{id}/boosts/new", "/messages/#{id}/boosts"].each do |path|
      get path
      assert_equal 200, last_response.status, path
      assert Nokogiri::HTML5(last_response.body).at_css("turbo-frame"), path
    end
    header "Accept", "text/vnd.turbo-stream.html"
    mutate(:delete, "/rooms/#{room.id}/messages/#{id}")
    assert_equal 200, last_response.status
    assert_equal "message_browser-one", Nokogiri::HTML5.fragment(last_response.body).at_css("turbo-stream[action=remove]")["target"]
  end

  def test_autocomplete_scopes_mentions_to_room_and_escapes_names
    private_room = service.create_room(admin, {"name" => "Private"}, type: "Rooms::Closed", user_ids: [member.id])
    db[:users].where(id: member.id).update(name: '<b>Member</b>')
    sign_in
    get "/autocompletable/users", {room_id: private_room.id, filter: "Member"}
    item = Nokogiri::HTML5.fragment(last_response.body).at_css("lexxy-prompt-item")
    assert_equal '<b>Member</b>', item["search"]
    assert_equal member.id, container.tokens.verify(item["sgid"], purpose: :mention)
    refute item.at_css("b")
    header "Accept", "application/json"
    get "/autocompletable/users", {room_id: private_room.id, query: "Member"}
    row = JSON.parse(last_response.body).first
    assert_equal member.id, row["value"]
    assert_equal "&lt;b&gt;Member&lt;/b&gt;", row["name"]
    header "Accept", nil
    sign_in(outsider)
    get "/autocompletable/users", {room_id: private_room.id}
    assert_equal 404, last_response.status
  end

  def test_rich_formatting_signed_mentions_and_autolinks_survive_render_and_edit
    message = post_message(admin, room, "<p>Hi #{mention(member)}</p><p><u>under</u> <s>strike</s> <mark>mark</mark> https://example.com/</p><table><tbody><tr><td>cell</td></tr></tbody></table><pre data-language='ruby'>puts 1</pre>")
    assert_includes message[:plain_text], "Hi @Member"
    assert_equal [member.id], service.mentioned_user_ids(message[:body])
    assert_empty service.mentioned_user_ids("@Member hello")
    sign_in
    get "/rooms/#{room.id}/messages/#{message[:id]}"
    body = Nokogiri::HTML5(last_response.body).at_css("[data-reply-target=body]")
    assert_equal "Member", body.at_css(".mention").text.strip
    %w[u s mark table td pre[data-language=ruby]].each { |selector| assert body.at_css(selector), selector }
    assert body.at_css("a[href='https://example.com/'][target=_blank]")
    get "/rooms/#{room.id}/messages/#{message[:id]}/edit"
    value = Nokogiri::HTML5(last_response.body).at_css("lexxy-editor")["value"]
    attachment = Nokogiri::HTML5.fragment(value).at_css("action-text-attachment")
    assert_equal "application/vnd.campfire.mention", attachment["content-type"]
    assert_includes attachment["content"], 'class="mention"'
  end

  def test_link_embeds_rebuild_untrusted_content_and_drop_same_origin_urls
    fake = '<actiontext-opengraph-embed data-controller="evil"><div class="og-embed__title"><a href="/rooms/1">Title</a></div><div class="og-embed__image"><img src="/session" onload="evil()"></div></actiontext-opengraph-embed>'
    message = post_message(admin, room, %(<p>Preview <action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" content="#{CGI.escapeHTML(fake)}"></action-text-attachment></p>))
    sign_in
    get "/rooms/#{room.id}/messages/#{message[:id]}"
    embed = Nokogiri::HTML5(last_response.body).at_css("actiontext-opengraph-embed")
    assert_equal "Title", embed.at_css(".og-embed__title").text.strip
    refute embed.at_css("a, img, [data-controller]")
    refute_includes embed.to_html, "evil"
  end

  def test_autolinks_respect_nested_markup_existing_links_and_code
    message = post_message(admin, room, <<~HTML)
      <p><strong>prefix</strong>www.example.com <em>mail&#64;example.org</em> &lt;safe&gt;</p>
      <p><a href="https://existing.example/">https://existing.example/</a></p>
      <pre><code>https://code.example/</code></pre><p><code>www.inline.example</code></p>
      <p><em>https://one.example/</em> and https://two.example/.</p>
    HTML
    sign_in
    get "/rooms/#{room.id}/messages/#{message[:id]}"
    body = Nokogiri::HTML5(last_response.body).at_css("[data-reply-target=body]")
    assert_equal ["http://www.example.com", "mailto:mail@example.org", "https://existing.example/", "https://one.example/", "https://two.example/"],
      body.css("a").map { |link| link["href"] }
    assert_empty body.css("a a, code a, pre a, safe")
    assert_includes body.text, "<safe>"
    assert_includes body.text, "https://two.example/."
    get "/rooms/#{room.id}/messages/#{message[:id]}/edit"
    editor = Nokogiri::HTML5(last_response.body).at_css("lexxy-editor")
    assert_equal ["https://existing.example/"], Nokogiri::HTML5.fragment(editor["value"]).css("a").map { |link| link["href"] }
  end

  def test_sound_and_room_refresh_render_turbo_content
    message = post_message(admin, room, "/play bell")
    sign_in
    assert Nokogiri::HTML5(last_response.body).at_css("[data-controller=sound][data-sound-url-value]")
    header "Accept", "text/vnd.turbo-stream.html"
    get "/rooms/#{room.id}/refresh", {since: 0}
    assert_equal 200, last_response.status
    assert Nokogiri::HTML5.fragment(last_response.body).at_css("turbo-stream[action=append] [data-message-id='#{message[:id]}']")
    header "Accept", nil
    mutate(:put, "/rooms/#{room.id}/involvement", {involvement: "nothing"})
    follow_redirect!
    assert Nokogiri::HTML5(last_response.body).at_css("#involvement_room_#{room.id} button.nothing")
  end
end
