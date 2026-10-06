# frozen_string_literal: true

require "uri"

module Campfire
  module UI
    class RichText
      EMBED_TYPE = "application/vnd.actiontext.opengraph-embed"
      MENTION_TYPE = "application/vnd.campfire.mention"
      Embed = Struct.new(:href, :url, :filename, :description) do
        def twitter_avatar? = url.to_s.start_with?("https://pbs.twimg.com/profile_images")
      end

      def initialize(view) = @view = view

      def render(body, editing: false, presentation: true)
        fragment = Nokogiri::HTML5.fragment(body.to_s)
        nodes = fragment.css("action-text-attachment")
        remove_solo_unfurled_link(fragment, nodes) if presentation && !editing
        nodes.each do |node|
          html, type = attachment(node)
          if editing
            node.attribute_nodes.each { |attr| node.remove_attribute(attr.name) unless attr.name == "sgid" }
            node["content-type"], node["content"] = type, html.to_s
          else
            node.replace(html.to_s)
          end
        end
        autolink(fragment) if presentation && !editing
        @view.raw(fragment.to_html)
      end

      private

      def attachment(node)
        if node["content-type"] == EMBED_TYPE
          embed = embed_from(node)
          [@view.render("action_text/attachables/opengraph_embed", opengraph_embed: embed), EMBED_TYPE]
        elsif id = @view.context.container.tokens.verify(node["sgid"], purpose: :mention)
          user = @view.context.user(id)
          [@view.render("users/mention", user: user), MENTION_TYPE]
        else
          [@view.tag.figure("Missing attachment", class: "attachment attachment--missing"), "application/octet-stream"]
        end
      rescue Campfire::Error
        [@view.tag.figure("Missing attachment", class: "attachment attachment--missing"), "application/octet-stream"]
      end

      def embed_from(node)
        if !node["filename"].to_s.empty?
          Embed.new(web_url(node["href"]), web_url(node["url"]), node["filename"], node["caption"])
        else
          content = Nokogiri::HTML5.fragment(node["content"].to_s)
          title = content.at_css(".og-embed__title")
          link = title&.at_css("a")
          Embed.new(web_url(link&.[]("href")), web_url(content.at_css(".og-embed__image img")&.[]("src")),
            (link || title)&.text.to_s.strip, content.at_css(".og-embed__description")&.text.to_s.strip)
        end
      end

      def web_url(value)
        uri = URI.parse(value.to_s)
        host = uri.host.to_s.downcase.delete_suffix(".")
        label = host.split(".").last.to_s
        return unless uri.is_a?(URI::HTTP) && !uri.userinfo && host.include?(".") && !host.include?("%")
        return unless label.match?(/[a-z]/i) && !label.match?(/\A0x/i)
        value if host != @view.request.host.downcase.delete_suffix(".")
      rescue URI::InvalidURIError
        nil
      end

      def remove_solo_unfurled_link(fragment, nodes)
        embeds = nodes.select { |node| node["content-type"] == EMBED_TYPE }
        return unless embeds.length == 1
        url = embed_from(embeds.first).href
        return if url.to_s.empty?
        text = fragment.dup
        text.css("action-text-attachment").remove
        return unless normalized_url(text.text.strip) == normalized_url(url)
        fragment.children.remove
        fragment.add_child(embeds.first)
      end

      def normalized_url(value)
        uri = URI.parse(value)
        if %w[x.com twitter.com].include?(uri.host&.downcase)
          uri.host, uri.query = "twitter.com", nil
        end
        uri.to_s
      rescue URI::InvalidURIError
        value
      end

      def autolink(fragment)
        fragment.xpath(".//text()").each do |text|
          next if text.ancestors.any? { |parent| %w[a pre code].include?(parent.name) }
          source = text.text
          pattern = %r{https?://[^\s<>]+|\bwww\.[^\s<>]+|\b[\w.+-]+@[\w.-]+\.[a-z]{2,}\b}i
          next unless source.match?(pattern)
          html, previous = +"", 0
          source.to_enum(:scan, pattern).each do
            match = Regexp.last_match
            value = match[0].sub(/[.,!?;:)]+\z/, "")
            html << CGI.escapeHTML(source[previous...match.begin(0)])
            href = value.start_with?("www.") ? "http://#{value}" : value.include?("@") && !value.include?("://") ? "mailto:#{value}" : value
            html << %(<a href="#{CGI.escapeHTML(href)}" target="_blank" rel="nofollow noopener noreferrer">#{CGI.escapeHTML(value)}</a>)
            html << CGI.escapeHTML(match[0].delete_prefix(value))
            previous = match.end(0)
          end
          html << CGI.escapeHTML(source[previous..])
          text.replace(html)
        end
      end
    end
  end
end
