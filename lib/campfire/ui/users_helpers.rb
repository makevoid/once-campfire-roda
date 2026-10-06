# frozen_string_literal: true
# Adapted from Campfire presentation helpers, MIT, copyright 37signals, LLC.

module Campfire
  module UI
    module UsersHelpers
      def button_to_direct_room_with(user)
        button_to "/rooms/directs?user_ids[]=#{user.id}", class: "btn btn--primary full-width txt--large" do
          image_tag("messages.svg")
        end
      end

      def sidebar_turbo_frame_tag(src: nil, &)
        turbo_frame_tag :user_sidebar, src: src, target: "_top", data: {
          turbo_permanent: true,
          controller: "rooms-list read-rooms turbo-frame",
          rooms_list_unread_class: "unread",
          action: "presence:present@window->rooms-list#read read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded refresh-room:visible@window->turbo-frame#reload" # Escaped attributes preserve the same DOM action value.
        }, &
      end

      def profile_form_with(model, **params, &)
        form_with \
          model: @user, url: "/users/me/profile", method: :patch,
          data: { controller: "form" },
          **params,
          &
      end

      def profile_form_submit_button
        tag.button class: "btn btn--reversed center txt-large", type: "submit" do
          image_tag("check.svg", aria: { hidden: "true" }, size: 20) +
          tag.span("Save changes", class: "for-screen-reader")
        end
      end

      def web_share_session_button(url, title, text, &)
        tag.button class: "btn", hidden: true, data: {
          controller: "web-share", action: "web-share#share",
          web_share_url_value: url,
          web_share_text_value: text,
          web_share_title_value: title
        }, &
      end

      AVATAR_COLORS = %w[
        #AF2E1B #CC6324 #3B4B59 #BFA07A #ED8008 #ED3F1C #BF1B1B #736B1E #D07B53
        #736356 #AD1D1D #BF7C2A #C09C6F #698F9C #7C956B #5D618F #3B3633 #67695E
      ]

      def avatar_background_color(user)
        AVATAR_COLORS[Zlib.crc32(user.to_param) % AVATAR_COLORS.size]
      end

      def avatar_tag(user, **options)
        link_to "/users/#{user.id}", title: user.title, class: "btn avatar", data: { turbo_frame: "_top" } do
          image_tag avatar_url(user), aria: { hidden: "true" }, size: 48, **options
        end
      end

      def user_filter_menu_tag(&)
        tag.menu class: "flex flex-column gap margin-none pad overflow-y constrain-height",
          data: { controller: "filter", filter_active_class: "filter--active", filter_selected_class: "selected" }, &
      end

      def user_filter_search_tag
        tag.input type: "search", id: "search", autocorrect: "off", autocomplete: "off", "data-1p-ignore": "true", class: "input input--transparent full-width", placeholder: "Filter…", data: { action: "input->filter#filter" }
      end
    end
  end
end
