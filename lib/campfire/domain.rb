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

require_relative "content"
