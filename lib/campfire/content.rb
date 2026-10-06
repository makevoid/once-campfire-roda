# frozen_string_literal: true

module Campfire
  # Store safe editor markup, keeping typed attachment data for reconstruction by
  # the renderer. Author-supplied attachment HTML is never inserted into a page.
  class Content
    TAGS = %w[a abbr acronym address b big blockquote br cite code dd del dfn div dl dt em h1 h2 h3 h4 h5 h6 hr i ins kbd li ol p pre samp small span strong sub sup time tt ul var s u mark table thead tbody tfoot tr th td figure figcaption action-text-attachment].freeze
    DROP = %w[script style iframe object embed svg math template].freeze
    ATTRIBUTES = %w[class title dir lang datetime cite start reversed value colspan rowspan abbr scope data-language].freeze
    ATTACHMENT_ATTRIBUTES = %w[sgid content-type content url href filename caption].freeze
    attr_reader :html, :text

    def empty? = text.empty? && !@embedded

    def initialize(body, mention_name: nil)
      raise Error, "Message is too large" if body.to_s.bytesize > 100_000
      body = body.to_s.dup.force_encoding(Encoding::UTF_8)
      raise Error, "Message must use valid UTF-8" unless body.valid_encoding?
      fragment = Nokogiri::HTML5.fragment(body)
      fragment.traverse do |node|
        next unless node.element?
        if DROP.include?(node.name)
          node.remove
        elsif !TAGS.include?(node.name)
          node.replace(node.children)
        else
          node.attribute_nodes.each do |attribute|
            keep = ATTRIBUTES.include?(attribute.name)
            keep = safe_url?(attribute.value) if %w[href cite].include?(attribute.name)
            keep = ATTACHMENT_ATTRIBUTES.include?(attribute.name) if node.name == "action-text-attachment"
            node.remove_attribute(attribute.name) unless keep
          end
          node["rel"] = "nofollow noopener noreferrer" if node.name == "a"
        end
      end
      @html = fragment.to_html.freeze
      @embedded = !fragment.at_css("action-text-attachment").nil?
      fragment.css("action-text-attachment").each do |node|
        name = mention_name&.call(node["sgid"])
        node.replace(Nokogiri::XML::Text.new(name.to_s, fragment.document))
      end
      fragment.css("br").each { |node| node.replace("\n") }
      fragment.css("p,div,li,pre,blockquote,tr").each { |node| node.add_next_sibling(Nokogiri::XML::Text.new("\n", fragment.document)) }
      @text = fragment.text.strip.freeze
    end

    def safe_url?(value)
      value.match?(%r{\A(?:https?://|mailto:|/(?!/)|#)}i)
    end
  end
end
