# frozen_string_literal: true
# Adapted from Campfire presentation helpers, MIT, copyright 37signals, LLC.

module Campfire
  module UI
    module SharedHelpers
      def page_title_tag
        tag.title @page_title || "Campfire"
      end

      def current_user_meta_tags
        unless current.user.nil?
          safe_join [
            tag(:meta, name: "current-user-id", content: current.user.id),
            tag(:meta, name: "current-user-name", content: current.user.name)
          ]
        end
      end

      def custom_styles_tag
        if custom_styles = current.account&.custom_styles
          tag.style(raw(custom_styles.to_s.gsub(%r{</style}i, "<\\/style")), data: { turbo_track: "reload" })
        end
      end

      def body_classes
        [ @body_class, admin_body_class, account_logo_body_class ].compact.join(" ")
      end

      def link_back
        back_url = request.referrer
        back_url = "/" if back_url.nil? || back_url == request.url
        link_back_to back_url
      end

      def link_back_to(destination)
        link_to destination, class: "btn" do
          image_tag("arrow-left.svg", aria: { hidden: "true" }, size: 20) +
          tag.span("Go Back", class: "for-screen-reader")
        end
      end
      def admin_body_class
        "admin" if current.user&.can_administer?
      end

      def account_logo_body_class
        "account-has-logo" if current.account&.logo&.attached?
      end

      def button_to_copy_to_clipboard(url, &)
        tag.button class: "btn", data: {
          controller: "copy-to-clipboard", action: "copy-to-clipboard#copy",
          copy_to_clipboard_success_class: "btn--success", copy_to_clipboard_content_value: url
        }, &
      end

      def auto_submit_form_with(**attributes, &)
        data = attributes.delete(:data) || {}
        data[:controller] = "auto-submit #{data[:controller]}".strip

        form_with(**attributes, data: data, &)
      end

      REACTIONS = {
        "👍" => "Thumbs up",
        "👏" => "Clapping",
        "👋" => "Waving hand",
        "💪" => "Muscle",
        "❤️" => "Red heart",
        "😂" => "Face with tears of joy",
        "🎉" => "Party popper",
        "🔥" => "Fire"
      }

      def drop_target_actions
        "dragenter->drop-target#dragenter dragover->drop-target#dragover drop->drop-target#drop"
      end

      def local_datetime_tag(datetime, style: :time, **attributes)
        tag.time(**attributes, datetime: datetime.iso8601, data: { local_time_target: style })
      end

      def account_logo_tag(style: nil)
        tag.figure image_tag(account_logo_url, alt: "Account logo", size: 300), class: "account-logo avatar #{style}"
      end

      def search_results_tag(&)
        tag.div id: "search-results", class: "messages searches__results", data: {
          controller: "search-results",
          search_results_target: "messages",
          search_results_me_class: "message--me",
          search_results_threaded_class: "message--threaded",
          search_results_mentioned_class: "message--mentioned",
          search_results_formatted_class: "message--formatted"
        }, &
      end

      def link_to_zoom_qr_code(url, &)
        id = Base64.urlsafe_encode64(url)

        link_to "/qr_code/#{id}", class: "btn", data: {
          lightbox_target: "image", action: "lightbox#open", lightbox_url_value: "/qr_code/#{id}" }, &
      end
    end
  end
end
