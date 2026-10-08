# frozen_string_literal: true

module Campfire
  module UI
    ModelName = Data.define(:singular, :plural) do
      def param_key = singular
      def collection = plural
      def route_key = plural
      def singular_route_key = singular
      def element = singular
      def human = singular.capitalize
    end

    class Pagination
      attr_reader :records
      def initialize(rows, page, per_page: 20)
        @number = [page.to_i, 1].max
        if rows.is_a?(Sequel::Dataset)
          portion = rows.limit(per_page + 1, (@number - 1) * per_page).all
          @last = portion.length <= per_page
          @records = portion.first(per_page)
        else
          @last = @number * per_page >= rows.length
          @records = rows.slice((@number - 1) * per_page, per_page) || []
        end
      end
      def last? = @last
      def next_param = (@number + 1).to_s
    end

    class Kind < String
      def method_missing(name, *args)
        return self == name.to_s.delete_suffix("?") if args.empty? && name.to_s.end_with?("?")
        super
      end
      def respond_to_missing?(name, *) = name.to_s.end_with?("?")
    end

    # Presentation adapters around Sequel rows. They never persist or authorize;
    # those responsibilities stay in Repository and Service.
    class Record
      attr_reader :attributes, :context

      def initialize(attributes = {}, context = nil)
        @attributes, @context = attributes, context
      end

      def self.model_name
        @model_name ||= begin
          singular = name.split("::").last.downcase
          ModelName.new(singular, "#{singular}s")
        end
      end
      def model_name = self.class.model_name
      def to_model = self
      def to_partial_path = "#{model_name.plural}/#{model_name.singular}"
      def id = @attributes[:id]
      def [](key) = @attributes[key.to_sym]
      def persisted? = !!id
      def new_record? = !persisted?
      def to_key = id ? [id] : nil
      def to_param = id&.to_s
      def errors = {}
      def cache_key = "#{model_name.collection}/#{id}-#{self[:updated_at]&.to_f}"
      def cache_version = self[:updated_at]&.to_f.to_s
      def ==(other) = other.is_a?(self.class) && id == other.id

      def method_missing(name, *args)
        return @attributes[name] if args.empty? && @attributes.key?(name)
        super
      end

      def respond_to_missing?(name, include_private = false)
        @attributes.key?(name) || super
      end
    end

    class Collection < Array
      def many? = length > 1
      def without(*values) = self.class.new(reject { |record| values.flatten.include?(record) })
      def pluck(name) = map { |record| record.public_send(name) }
      def ordered = self.class.new(sort_by { |record| record.respond_to?(:created_at) ? record.created_at : record.id })
      def active = self.class.new(select(&:active?))
      def without_bots = self.class.new(reject(&:bot?))
      def without_directs = self.class.new(reject(&:direct?))
      def paged? = length > 40
      def find_by(**attrs) = find { |record| attrs.all? { |key, value| record.public_send(key) == value } }
    end

    class User < Record
      def name = self[:name]
      def bio = self[:bio]
      def email_address = self[:email_address]
      def password = nil
      def title = @title ||= [name, bio].reject { |value| value.to_s.strip.empty? }.join(" – ")
      def initials = name.to_s.scan(/\b\w/).join
      def administrator? = self[:role] == 1
      def bot? = self[:role] == 2
      def member? = self[:role] == 0
      def active? = self[:status] == 0
      def banned? = self[:status] == 2
      def deactivated? = self[:status] == 1
      def role = %w[member administrator bot][self[:role]]
      def can_administer?(record = nil) = administrator? || (record && record[:creator_id] == id)
      def avatar = context.media("User", id, "avatar")
      def avatar_token = @avatar_token ||= context.container.tokens.generate(id, purpose: :avatar)
      def transfer_id = context.container.tokens.generate(id, purpose: :transfer, expires_in: 14_400)
      def attachable_sgid = context.container.tokens.generate(id, purpose: :mention)
      def bot_key = "#{id}-#{self[:bot_token]}"
      def webhook_url = context.container.db[:webhooks].where(user_id: id).get(:url)
      def memberships = context.memberships_for(id)
      def rooms = Collection.new(memberships.map(&:room))
    end

    class Room < Record
      def name = self[:name]
      def direct? = self[:type] == "Rooms::Direct"
      def open? = self[:type] == "Rooms::Open"
      def closed? = self[:type] == "Rooms::Closed"
      def users = context.room_users(id)
      def messages = context.room_messages(id)
      def memberships = context.memberships_for_room(id)
      def creator = context.user(self[:creator_id])
      def route_kind = {"Rooms::Open" => "opens", "Rooms::Closed" => "closeds", "Rooms::Direct" => "directs"}.fetch(self[:type], "opens")
    end

    class Membership < Record
      def room = context.room(self[:room_id])
      def user = context.user(self[:user_id])
      def unread? = !self[:unread_at].nil?
    end

    class Account < Record
      def logo = context.media("Account", id, "logo")
      def settings = Settings.new(JSON.parse(self[:settings] || "{}"))
    end

    class Settings
      def initialize(values) = @values = values
      def restrict_room_creation_to_administrators? = !!@values["restrict_room_creation_to_administrators"]
    end

    class Body
      def initialize(attributes) = @attributes = attributes
      def body = @attributes[:body].to_s
      def body_before_type_cast = body
      def to_s = body
      def to_plain_text = @attributes[:plain_text].to_s
    end

    class Message < Record
      def to_param = id&.to_s
      def body = Body.new(@attributes)
      def plain_text_body = self[:plain_text].to_s
      def creator = context.user(self[:creator_id])
      def room = context.room(self[:room_id])
      def boosts = context.boosts_for(id)
      def attachment = context.attachment_for(id)
      def attachment? = attachment.attached?
      def sound = Sound.find_by_name(plain_text_body[/\A\/play (\w+)\z/, 1])
      def content_type = Kind.new(attachment? ? "attachment" : sound ? "sound" : "text")
    end

    class Boost < Record
      def content = self[:content]
      def booster = context.user(self[:booster_id])
      def message = context.message(self[:message_id])
    end

    class Attachment < Record
      def attached? = !!self[:key]
      def variable? = Campfire::Uploads::IMAGE_TYPES.include?(self[:content_type])
      def previewable? = video? || self[:content_type] == "application/pdf"
      def video? = self[:content_type].to_s.start_with?("video/")
      def filename = self[:filename]
      def metadata = JSON.parse(self[:metadata] || "{}").transform_keys(&:to_sym)
      def representation(name) = Variant.new(self, name)
      def preview(**) = Variant.new(self, :thumb)
    end

    Variant = Data.define(:file, :name)

    class Context
      Current = Data.define(:user, :account)
      attr_reader :container, :current

      def initialize(container, actor, page: nil)
        @container = container
        @users, @rooms, @messages, @boosts, @attachments, @media = {}, {}, {}, {}, {}, {}
        @users[actor.id] = User.new(actor.attributes, self) if actor
        account = container.repo.account
        @current = Current.new(actor && @users[actor.id], account && Account.new(account, self))
        load_page(page) if page
      end

      def load_page(page)
        creator_ids = page.messages.map { |row| row[:creator_id] } + page.boosts.values.flatten.map { |row| row[:booster_id] }
        container.db[:users].where(id: creator_ids.uniq).all.each { |row| @users[row[:id]] = User.new(row, self) }
        container.db[:rooms].where(id: page.messages.map { |row| row[:room_id] }.uniq).all.each { |row| @rooms[row[:id]] = Room.new(row, self) }
        page.messages.each { |row| @messages[row[:id]] = Message.new(row, self) }
        page.boosts.each { |id, rows| @boosts[id] = Collection.new(rows.map { |row| Boost.new(row, self) }) }
        page.attachments.each { |id, rows| @attachments[id] = Attachment.new(rows.first || {}, self) }
      end

      def user(id) = @users[id] ||= User.new(container.repo.user(id).attributes, self)
      def room(id) = @rooms[id] ||= Room.new(container.db[:rooms][id: id] || {}, self)
      def message(id) = @messages[id] ||= Message.new(container.db[:messages][id: id] || {}, self)
      def boosts_for(id) = @boosts[id] ||= Collection.new
      def attachment_for(id) = @attachments[id] ||= Attachment.new({}, self)
      def media(type, id, purpose) = @media[[type, id, purpose]] ||= Attachment.new(container.media.find(type, id, purpose) || {}, self)
      def room_messages(id) = Collection.new(container.db[:messages].where(room_id: id).order(:created_at).limit(41).all.map { |row| Message.new(row, self) })

      def room_users(id)
        @room_users ||= {}
        @room_users[id] ||= Collection.new(container.db[:users].join(:memberships, user_id: :id).where(room_id: id).select_all(:users).all.map do |row|
          @users[row[:id]] ||= User.new(row, self)
        end)
      end

      def memberships_for(id)
        Collection.new(container.db[:memberships].where(user_id: id).all.map { |row| Membership.new(row, self) })
      end

      def memberships_for_room(id)
        Collection.new(container.db[:memberships].where(room_id: id).all.map { |row| Membership.new(row, self) })
      end

      def page_messages(page) = Collection.new(page.messages.map { |row| message(row[:id]) })

      def sidebar(data)
        rows = data[:shared] + data[:direct]
        rows.each { |row| @rooms[row[:id]] = Room.new(row, self) }
        @room_users ||= {}
        direct_ids = data[:direct].map { |row| row[:id] }
        participants = container.db[:users].join(:memberships, user_id: :id).where(room_id: direct_ids)
          .select_all(:users).select_append(:room_id).all
        participants.group_by { |row| row[:room_id] }.each do |id, users|
          @room_users[id] = Collection.new(users.map { |row| @users[row[:id]] ||= User.new(row, self) })
        end
        container.db[:users].where(id: data[:people].map { |row| row[:id] }).all.each { |row| @users[row[:id]] ||= User.new(row, self) }
        wrap = ->(room) { Membership.new({room_id: room[:id], user_id: current.user.id, unread_at: room[:unread_at]}, self) }
        {direct_memberships: Collection.new(data[:direct].map(&wrap)), other_memberships: Collection.new(data[:shared].map(&wrap)),
          direct_placeholder_users: Collection.new(data[:people].map { |row| user(row[:id]) })}
      end
    end
  end
end
