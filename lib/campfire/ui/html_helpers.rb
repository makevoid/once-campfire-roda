# frozen_string_literal: true

module Campfire
  module UI
    module HTMLHelpers
      BOOLEAN_ATTRIBUTES = %w[allowfullscreen async autofocus autoplay checked controls default defer disabled formnovalidate hidden inert ismap itemscope loop multiple muted nomodule novalidate open playsinline readonly required reversed selected].freeze

      def raw(value) = HTML.new(value.to_s)
      def h(value) = value.is_a?(HTML) ? value : raw(CGI.escapeHTML(value.to_s))
      def safe_join(values, separator = "") = raw(values.map { |value| h(value) }.join(h(separator)))
      def concat(value) = @output_buffer.append = value
      def epoch(time) = (time.to_f * 1000).to_i
      def emoji_only?(text) = /\A(\p{Emoji_Presentation}|\p{Extended_Pictographic}|\uFE0F)+\z/u.match?(text.to_s)

      def sentence(values, two_words_connector: " and ")
        case values.length
        when 0 then ""
        when 1 then values.first.to_s
        when 2 then values.join(two_words_connector)
        else "#{values[0...-1].join(', ')}, and #{values.last}"
        end
      end

      def capture(*args)
        previous = @output_buffer
        @output_buffer = Buffer.new
        value = yield(*args)
        @output_buffer.empty? ? h(value.is_a?(String) ? value : "") : @output_buffer.to_s
      ensure
        @output_buffer = previous
      end

      def content_for(name, value = nil, &block)
        @contents[name.to_sym] ||= raw("")
        @contents[name.to_sym] = raw(@contents[name.to_sym] + (block ? capture(&block) : h(value)))
        nil
      end

      def tag(name = nil, **attrs, &block)
        return TagBuilder.new(self) unless name
        element(name, nil, attrs, &block)
      end

      def element(name, content = nil, attrs = {}, &block)
        name = name.to_s.tr("_", "-")
        raise ArgumentError, "Invalid element" unless name.match?(/\A[a-z][a-z0-9-]*\z/i)
        opening = "<#{name}#{html_attributes(attrs)}>"
        return raw(opening) if %w[area base br col embed hr img input link meta param source track wbr].include?(name)
        raw(opening + (block ? capture(&block) : h(content)) + "</#{name}>")
      end

      def html_attributes(attrs)
        attrs.flat_map do |name, value|
          key = name.to_s.tr("_", "-")
          next [] if value.nil? || value == false
          if %w[data aria].include?(key) && value.is_a?(Hash)
            value.map do |subkey, subvalue|
              next if subvalue.nil?
              subvalue = JSON.generate(subvalue) if subvalue.is_a?(Array) || subvalue.is_a?(Hash)
              %( #{key}-#{subkey.to_s.tr('_', '-')}="#{CGI.escapeHTML(subvalue.to_s)}")
            end.compact
          else
            next [] unless key.match?(/\A[a-zA-Z_:][a-zA-Z0-9_:.-]*\z/)
            value = class_names(value) if key == "class"
            value = key if BOOLEAN_ATTRIBUTES.include?(key) && value == true
            [%( #{key}="#{CGI.escapeHTML(value.to_s)}")]
          end
        end.join
      end

      def class_names(value)
        case value
        when Hash then value.filter_map { |name, enabled| name.to_s if enabled }.join(" ")
        when Array then value.map { |entry| class_names(entry) }.reject(&:empty?).join(" ")
        else value.to_s
        end
      end

      def link_to(label = nil, destination = nil, options = {}, **attrs, &block)
        if block
          attrs = (destination.is_a?(Hash) ? destination : {}).merge(options).merge(attrs)
          destination, label = label, nil
        end
        element("a", label, {href: url_for(destination)}.merge(options).merge(attrs), &block)
      end

      def link_to_if(condition, label, destination, **attrs)
        condition ? link_to(label, destination, **attrs) : h(label)
      end

      def mail_to(address) = link_to(address, "mailto:#{address}")

      def image_tag(source, options = {}, **attrs)
        attrs = options.merge(attrs)
        if dimensions = attrs.delete(:size)
          width, height = dimensions.to_s.split("x")
          attrs[:width] ||= width
          attrs[:height] ||= height || width
        end
        element("img", nil, {src: asset_path(source)}.merge(attrs))
      end

      def dom_id(record, prefix = nil)
        return [prefix, record].compact.join("_") if record.is_a?(String) || record.is_a?(Symbol)
        parts = record.to_key
        [prefix || ("new" unless parts), record.model_name.singular, *parts].compact.join("_")
      end

      def turbo_frame_tag(*ids, **attrs, &block)
        ids = [dom_id(*ids)] if ids.first.respond_to?(:to_key)
        element("turbo-frame", nil, {id: ids.join("_")}.merge(attrs), &block)
      end

      def turbo_exempts_page_from_preview = tag.meta(name: "turbo-cache-control", content: "no-preview")
      def turbo_page_requires_reload = content_for(:head, tag.meta(name: "turbo-visit-control", content: "reload"))
      def truncate(value, length: 30, omission: "...") = value.to_s.length > length ? "#{value.to_s[0, length - omission.length]}#{omission}" : value.to_s

      class TagBuilder
        def initialize(view) = @view = view
        def method_missing(name, content = nil, **attrs, &block) = @view.element(name, content, attrs, &block)
        def respond_to_missing?(*args) = true
      end
    end
  end
end
