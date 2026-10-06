# frozen_string_literal: true
# Adapted from Campfire, MIT, copyright 37signals, LLC.
module Campfire
  module UI
class AttachmentPresentation
  def initialize(message, context:)
    @message, @context = message, context
  end

  def render
    if message.attachment.attached?
      if message.attachment.previewable? || message.attachment.variable?
        render_preview
      else
        render_link
      end
    end
  end

  private
    attr_reader :message, :context
    def tag = context.tag
    def link_to(...) = context.link_to(...)
    def broadcast_image_tag(...) = context.image_tag(...)
    def url_for(value) = context.asset_path(value)
    def file_url(file, disposition: nil, **)
      "/attachments/#{file.id}#{'?inline=1' unless disposition == 'attachment'}"
    end

    def render_preview
      if message.attachment.video?
        video_preview_tag
      else
        lightboxed_image_preview_tag
      end
    end

    def video_preview_tag
      width, height = preview_dimensions

      inline_media_dimension_constraints(width, height) do
        tag.video \
          src: file_url(message.attachment), poster: url_for(message.attachment.preview(format: :webp, resize_to_limit: [ 1200, 800 ])),
          controls: true, preload: :none, width: "100%", height: "100%", class: "message__attachment"
      end
    end

    def lightboxed_image_preview_tag
      width, height = preview_dimensions

      inline_media_dimension_constraints(width, height) do
        lightbox_link do
          broadcast_image_tag message.attachment.representation(:thumb), width: width, height: height, class: "message__attachment", loading: "lazy"
        end
      end
    end

    def inline_media_dimension_constraints(width, height, &)
      if width && height
        aspect_ratio = (width / height.to_f)

        tag.div class: "max-inline-size center flex overflow-clip", style: "width: #{width / 2}px; aspect-ratio: #{aspect_ratio};", &
      else
        tag.div class: "max-inline-size center overflow-clip", &
      end
    end

    def preview_dimensions
      width = message.attachment.metadata[:width]
      height = message.attachment.metadata[:height]

      case
      when width.nil? || height.nil?
        [ nil, nil ]
      when width <= 1200 && height <= 800
        [ width, height ]
      else
        width_factor = 1200.to_f / width
        height_factor = 800.to_f / height
        scale_factor = [ width_factor, height_factor ].min

        [ width * scale_factor, height * scale_factor ]
      end
    end

    def render_link
      tag.div class: "flex-inline align-center gap-half" do
        broadcast_image_tag("common-file-text.svg", size: 22, class: "colorize--black", aria: { hidden: "true" }) +
          tag.span(filename) + download_link + share_button
      end
    end

    def lightbox_link(&)
      link_to file_url(message.attachment), class: "flex", data: {
        lightbox_target: "image", action: "lightbox#open", lightbox_url_value: download_url }, &
    end

    def download_link
      link_to download_url, class: "btn message__action-btn hide-in-ios-pwa", style: "--width: auto;" do
        broadcast_image_tag("download.svg", aria: { hidden: "true" }, size: 20) + tag.span("Download #{ filename }", class: "for-screen-reader")
      end
    end

    def share_button
      tag.button class: "btn message__action-btn", style: "--width: auto;", data: { controller: "web-share", action: "web-share#share", web_share_files_value: download_url } do
        broadcast_image_tag("share.svg", aria: { hidden: "true" }, size: 20) + tag.span("Share #{ filename }", class: "for-screen-reader")
      end
    end

    def filename
      message.attachment.filename.to_s
    end

    def download_url
      file_url message.attachment, disposition: "attachment", only_path: true
    end
end

  end
end
