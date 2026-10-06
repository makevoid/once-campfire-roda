# frozen_string_literal: true
# Adapted from Campfire presentation helpers, MIT, copyright 37signals, LLC.

module Campfire
  module UI
    module RoomsHelpers
      def link_to_room(room, **attributes, &)
        link_to "/rooms/#{room.id}", **attributes, data: {
          rooms_list_target: "room", room_id: room.id, badge_dot_target: "unread", sorted_list_target: "item"
        }.merge(attributes.delete(:data) || {}), &
      end

      def link_to_edit_room(room, &)
        link_to \
          "/rooms/#{@room.route_kind}/#{@room.id}/edit",
          class: "btn",
          style: "view-transition-name: edit-room-#{@room.id}",
          data: { room_id: @room.id },
          &
      end

      def link_back_to_last_room_visited
        if last_room = last_room_visited
          link_back_to "/rooms/#{last_room.id}"
        else
          link_back_to "/"
        end
      end

      def button_to_delete_room(room, url: nil)
        button_to url || "/rooms/#{room.id}", method: :delete, class: "btn btn--negative max-width", aria: { label: "Delete #{room.name}" },
            data: { turbo_confirm: "Are you sure you want to delete this room and all messages in it? This can’t be undone." } do
          image_tag("trash.svg", aria: { hidden: "true" }, size: 20) +
          tag.span(room_display_name(room), class: "overflow-ellipsis")
        end
      end

      def button_to_jump_to_newest_message
        tag.button \
            class: "message-area__return-to-latest btn",
            data: { action: "messages#returnToLatest", messages_target: "latest" },
            hidden: true do
          image_tag("arrow-down.svg", aria: { hidden: "true" }, size: 20) +
          tag.span("Jump to newest message", class: "for-screen-reader")
        end
      end

      def submit_room_button_tag
        button_tag class: "btn btn--reversed txt-large center", type: "submit" do
          image_tag("check.svg", aria: { hidden: "true" }, size: 20) +
          tag.span("Save", class: "for-screen-reader")
        end
      end

      def composer_form_tag(room, &)
        form_with model: new_message, url: "/rooms/#{room.id}/messages",
          id: "composer", class: "margin-block flex-item-grow contain", data: composer_data_options(room), &
      end

      def room_display_name(room, for_user: current.user)
        if room.direct?
          (names = room.users.without(for_user).pluck(:name)).empty? ? for_user&.name : sentence(names)
        else
          room.name
        end
      end
      def composer_data_options(room)
        {
          controller: "composer drop-target",
          action: composer_data_actions,
          composer_messages_outlet: "#message-area",
          composer_toolbar_class: "composer--rich-text", composer_room_id_value: room.id
        }
      end

      def composer_data_actions
        drag_and_drop_actions = "drop-target:drop@window->composer#dropFiles"

        attachment_actions =
          "lexxy:file-accept->composer#preventAttachment refresh-room:online@window->composer#online"

        remaining_actions =
          "typing-notifications#stop paste->composer#pasteFiles turbo:submit-end->composer#submitEnd refresh-room:offline@window->composer#offline"

        [ drop_target_actions, drag_and_drop_actions, attachment_actions, remaining_actions ].join(" ")
      end

      def turbo_frame_for_involvement_tag(room, &)
        turbo_frame_tag dom_id(room, :involvement), data: {
          controller: "turbo-frame", action: "notifications:ready@window->turbo-frame#load", turbo_frame_url_param: "/rooms/#{room.id}/involvement"
        }, &
      end

      def button_to_change_involvement(room, involvement)
        button_to "/rooms/#{room.id}/involvement?involvement=#{next_involvement_for(room, involvement: involvement)}",
          method: :put,
          role: "checkbox", aria: { checked: true, labelledby: dom_id(room, :involvement_label) }, tabindex: 0,
          class: "btn #{involvement}" do
            image_tag("notification-bell-#{involvement}.svg", aria: { hidden: "true" }, size: 20) +
            tag.span(HUMANIZE_INVOLVEMENT[involvement], class: "for-screen-reader", id: dom_id(room, :involvement_label))
        end
      end
      HUMANIZE_INVOLVEMENT = {
        "mentions" => "Notifying about @ mentions",
        "everything" => "Notifying about all messages",
        "nothing" => "Notifications are off",
        "invisible" => "Notifications are off and room invisible in sidebar"
      }

      SHARED_INVOLVEMENT_ORDER = %w[ mentions everything nothing invisible ]
      DIRECT_INVOLVEMENT_ORDER = %w[ everything nothing ]

      def next_involvement_for(room, involvement:)
        order = room.direct? ? DIRECT_INVOLVEMENT_ORDER : SHARED_INVOLVEMENT_ORDER
        index = order.index(involvement)
        # Hidden direct chats remain in the profile so their notifications can
        # be re-enabled, even though "invisible" is outside the direct cycle.
        index ? order[(index + 1) % order.length] : order.first
      end
    end
  end
end
