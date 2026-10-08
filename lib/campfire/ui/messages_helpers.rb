# frozen_string_literal: true
# Adapted from Campfire, MIT, copyright 37signals, LLC.
module Campfire
  module UI
    module MessagesHelpers
  def message_area_tag(room, &)
    tag.div id: "message-area", class: "message-area", contents: true, data: {
      controller: "messages presence drop-target",
      action: [ messages_actions, drop_target_actions, presence_actions ].join(" "),
      messages_first_of_day_class: "message--first-of-day",
      messages_formatted_class: "message--formatted",
      messages_me_class: "message--me",
      messages_mentioned_class: "message--mentioned",
      messages_threaded_class: "message--threaded",
      messages_page_url_value: "/rooms/#{room.id}/messages"
    }, &
  end

  def messages_tag(room, &)
    tag.div id: dom_id(room, :messages), class: "messages", data: {
      controller: "maintain-scroll refresh-room",
      action: [ maintain_scroll_actions, refresh_room_actions ].join(" "),
      messages_target: "messages",
      refresh_room_loaded_at_value: epoch(room.updated_at),
      refresh_room_url_value: "/rooms/#{room.id}/refresh"
    }, &
  end

  def message_tag(message, &)
    message_timestamp_milliseconds = epoch(message.created_at)

    tag.div id: dom_id(message),
      class: "message #{"message--emoji" if emoji_only?(message.plain_text_body)}",
      data: {
        controller: "reply",
        user_id: message.creator_id,
        message_id: message.id,
        client_message_id: message[:client_message_id],
        message_timestamp: message_timestamp_milliseconds,
        message_updated_at: epoch(message.updated_at),
        sort_value: message_timestamp_milliseconds,
        messages_target: "message",
        search_results_target: "message",
        refresh_room_target: "message",
        reply_composer_outlet: "#composer"
      }, &

  end

  def message_timestamp(message, **attributes)
    local_datetime_tag message.created_at, **attributes
  end

  def message_presentation(message)
    case message.content_type
    when "attachment"
      message_attachment_presentation(message)
    when "sound"
      message_sound_presentation(message)
    else
      tag.div(RichText.new(self).render(message.body.to_s), class: "lexxy-content")
    end
  end

  def rich_text_data_actions
    "lexxy:change->typing-notifications#start keydown->composer#submitByKeyboard:capture"
  end

  def mention_prompt_tag(room)
    tag.lexxy_prompt trigger: "@", name: "mention", src: "/autocompletable/users?room_id=#{room.id}",
      "remote-filtering": true, "empty-results": "No matches"
  end

  def editable_body(message) = RichText.new(self).render(message.body.to_s, editing: true)

  private
    def messages_actions
      "turbo:before-stream-render@document->messages#beforeStreamRender keydown.up@document->messages#editMyLastMessage"
    end

    def maintain_scroll_actions
      "turbo:before-stream-render@document->maintain-scroll#beforeStreamRender"
    end

    def refresh_room_actions
      "visibilitychange@document->refresh-room#visibilityChanged online@window->refresh-room#online"
    end

    def presence_actions
      "visibilitychange@document->presence#visibilityChanged"
    end

    def message_attachment_presentation(message)
      AttachmentPresentation.new(message, context: self).render
    end

    def message_sound_presentation(message)
      sound = message.sound

      tag.div class: "sound", data: { controller: "sound", action: "messages:play->sound#play", sound_url_value: asset_path(sound.asset_path) } do
        play_button + (sound.image ? sound_image_tag(sound.image) : sound.text)
      end
    end

    def play_button
      tag.button "🔊", class: "btn btn--plain", data: { action: "sound#play" }
    end

    def sound_image_tag(image)
      image_tag image.asset_path, width: image.width, height: image.height, class: "align--middle"
    end

    def message_author_title(author)
      [author.name, author.bio].reject { |value| value.to_s.strip.empty? }.join(" – ")
    end
    end
  end
end
