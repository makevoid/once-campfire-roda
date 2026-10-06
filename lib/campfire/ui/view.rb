# frozen_string_literal: true

require_relative "engine"
require_relative "records"
require_relative "html_helpers"
require_relative "forms"
require_relative "assets"
require_relative "shared_helpers"
require_relative "rooms_helpers"
require_relative "users_helpers"
require_relative "translations_helpers"
require_relative "messages_helpers"
require_relative "platform"
require_relative "rich_text"
require_relative "attachment_presentation"

module Campfire
  module UI
    class View
      include HTMLHelpers
      include Forms
      include Assets
      include SharedHelpers
      include RoomsHelpers
      include UsersHelpers
      include TranslationsHelpers
      include MessagesHelpers
      ENGINE = Engine.new
      # Share compiled methods without allocating a singleton class per request.
      include ENGINE.templates
      attr_reader :context, :request, :current

      def initialize(container:, actor:, request:, csrf:, nonce:, page: nil, flash: {}, last_room_id: nil)
        @context = Context.new(container, actor, page: page)
        @request, @csrf, @nonce, @flash = request, csrf, nonce, flash
        @current, @contents, @last_room_id = context.current, {}, last_room_id
      end

      def page(name, assigns = {}, layout: true, **values)
        assigns.merge(values).each { |key, value| instance_variable_set("@#{key}", value) }
        content = ENGINE.render(self, name)
        layout ? ENGINE.render(self, "layouts/application") { |slot| slot ? @contents[slot] : content } : content
      end

      def render(name = nil, partial: nil, collection: nil, object: nil, as: nil, locals: {}, cached: false, layout: nil, **values, &block)
        return ENGINE.render(self, layout, locals.merge(values), partial: true) { capture(&block) } if layout
        name ||= partial
        if name.is_a?(Record)
          object, name = name, name.to_partial_path
        end
        locals = locals.merge(values)
        key = (as || File.basename(name).delete_prefix("_")).to_sym
        if collection
          safe_join(collection.map { |item| ENGINE.render(self, name, locals.merge(key => item), partial: true) })
        else
          locals = locals.merge(key => object) if object
          ENGINE.render(self, name, locals, partial: true)
        end
      end

      # Roda deliberately renders every response; this wrapper keeps the original
      # partial boundaries without bringing in Rails' fragment cache API.
      def cache(*) = yield
      def params = @params ||= request.params.transform_keys(&:to_sym)
      def flash = @flash
      def development? = ENV["RACK_ENV"] == "development"
      def platform = @platform ||= Platform.new(request.user_agent)
      def new_message = Message.new({}, context)
      def new_boost = Boost.new({}, context)
      def reaction_choices = SharedHelpers::REACTIONS
      def version_badge = "Roda port"
      def original_room = context.room(context.container.db[:rooms].order(:id).get(:id))
      def account_owner = context.user(context.container.db[:users].where(role: 1).order(:id).get(:id))
      def last_room_visited
        memberships = context.container.db[:memberships].where(user_id: current.user.id)
        id = memberships.where(room_id: @last_room_id).get(:room_id) || memberships.order(:id).get(:room_id)
        context.room(id) if id
      end
      def vapid_public_key = ENV.fetch("VAPID_PUBLIC_KEY", "")
      def csrf_meta_tags = safe_join([tag.meta(name: "csrf-param", content: "authenticity_token"), tag.meta(name: "csrf-token", content: @csrf)])
      def csp_meta_tag = tag.meta(name: "csp-nonce", content: @nonce)
      def script_aware_action_cable_meta_tag = tag.meta(name: "action-cable-url", content: "/cable")

      def turbo_stream_from(*names, channel: "Turbo::StreamsChannel")
        stream = names.map { |name| name.is_a?(Record) ? "#{name.model_name.singular}:#{name.id}" : name.to_s }.join(":")
        token = context.container.tokens.generate(stream, purpose: :stream)
        tag.turbo_cable_stream_source(channel: channel, "signed-stream-name": token)
      end

      def url_for(value)
        case value
        when nil then request.path
        when String then value
        when Variant then asset_path(value)
        when Array
          parent, record = value
          raise ArgumentError, "Unsupported form model" unless parent.is_a?(Message) && record.is_a?(Boost)
          "/messages/#{parent.id}/boosts#{"/#{record.id}" if record.persisted?}"
        when Room then "/rooms/#{value.route_kind}#{"/#{value.id}" if value.persisted?}"
        when Account then "/account"
        when User then "/users/#{value.id}"
        else raise ArgumentError, "Unsupported URL: #{value.class}"
        end
      end
    end
  end
end
