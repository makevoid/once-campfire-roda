# frozen_string_literal: true

require "json"
require "securerandom"
require "bcrypt"
require "nokogiri"
require "cgi/escape"

module Campfire
  class Error < StandardError
    attr_reader :status
    def initialize(message, status = 422)
      @status = status
      super(message)
    end
  end

  class User
    attr_reader :attributes
    def initialize(attributes)
      @attributes = attributes.freeze
    end
    def [](key) = @attributes[key]
    def id = self[:id]
    def administrator? = self[:role] == 1
    def bot? = self[:role] == 2
    def can_administer?(record) = administrator? || record[:creator_id] == id
  end

  class Room
    attr_reader :attributes
    def initialize(attributes)
      @attributes = attributes.freeze
    end
    def [](key) = @attributes[key]
    def id = self[:id]
    def direct? = self[:type] == "Rooms::Direct"
    def open? = self[:type] == "Rooms::Open"
  end

  # User-authored HTML is sanitized once on write, never while rendering a page.
  class Content
    TAGS = %w[p div br strong b em i u s del blockquote pre code ul ol li a h1 h2 h3 span].freeze
    DROP = %w[script style iframe object embed svg math template].freeze
    attr_reader :html, :text

    def initialize(body)
      raise Error, "Message is too large" if body.to_s.bytesize > 100_000
      body = body.to_s.dup.force_encoding(Encoding::UTF_8)
      raise Error, "Message must use valid UTF-8" unless body.valid_encoding?
      fragment = Nokogiri::HTML5.fragment(body.to_s)
      fragment.traverse do |node|
        next unless node.element?
        if DROP.include?(node.name)
          node.remove
        elsif !TAGS.include?(node.name)
          node.replace(node.children)
        else
          node.attribute_nodes.each do |attribute|
            keep = node.name == "a" && attribute.name == "href" && attribute.value.match?(%r{\A(?:https?://|mailto:|/(?!/)|#)}i)
            node.remove_attribute(attribute.name) unless keep
          end
          node["rel"] = "nofollow noopener noreferrer" if node.name == "a"
        end
      end
      @html = fragment.to_html.freeze
      fragment.css("br").each { |node| node.replace("\n") }
      fragment.css("p,div,li,pre,blockquote").each { |node| node.add_next_sibling(Nokogiri::XML::Text.new("\n", fragment.document)) }
      @text = fragment.text.strip.freeze
    end
  end

  class Page
    attr_reader :messages, :boosts, :attachments
    def initialize(messages, boosts: {}, attachments: {})
      @messages, @boosts, @attachments = messages, boosts, attachments
    end
    def empty? = messages.empty?
  end

  class UnreadFanout
    def initialize(adapter)
      @adapter = adapter
    end
    def broadcast(room_id, user_ids)
      payload = JSON.generate(roomId: room_id).freeze
      user_ids.each { |id| @adapter.broadcast("unread_rooms:#{id}", payload) }
    end
  end
end
