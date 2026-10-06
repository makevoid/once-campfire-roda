# frozen_string_literal: true

module Campfire
  module UI
    module Forms
      def form_with(model: nil, url: nil, method: nil, scope: nil, **attrs, &block)
        record = model.is_a?(Array) ? model.last : model
        scope ||= record&.model_name&.param_key
        method ||= record&.persisted? ? "patch" : "post"
        action = url_for(url || model || request.path)
        html = attrs.delete(:html) || {}
        attrs = html.merge(attrs)
        attrs.delete(:local)
        fields = capture(Form.new(self, record, scope), &block) if block
        method = method.to_s
        hidden = method == "get" ? raw("") : hidden_field_tag("authenticity_token", @csrf)
        hidden = raw(hidden + hidden_field_tag("_method", method)) unless %w[get post].include?(method)
        element("form", raw(hidden + fields.to_s), {action: action, method: method == "get" ? "get" : "post", enctype: "multipart/form-data"}.merge(attrs))
      end

      def button_to(label = nil, url = nil, method: "post", **attrs, &block)
        if block
          url, label = label, nil
        end
        form_attrs = attrs.delete(:form) || {}
        form_with(url: url, method: method, **form_attrs) do
          button = element("button", label, {type: "submit"}.merge(attrs), &block)
          concat(button)
        end
      end

      def button_tag(label = nil, **attrs, &block) = element("button", label, {type: "submit", name: "button"}.merge(attrs), &block)
      def hidden_field_tag(name, value = nil, **attrs) = tag.input(type: "hidden", name: name, value: value, **attrs)
      def text_field_tag(name, value = nil, **attrs) = tag.input(type: "text", name: name, value: value, **attrs)
      def check_box_tag(name, value, checked = false, **attrs) = tag.input(type: "checkbox", name: name, value: value, checked: checked, **attrs)
      def label_tag(name, label = nil, **attrs, &block) = element("label", label || name.to_s, {for: name}.merge(attrs), &block)

      class Form
        attr_reader :object
        def initialize(view, object, scope)
          @view, @object, @scope = view, object, scope
        end

        def field(name, type, **attrs)
          value = attrs.delete(:value)
          value = @object.public_send(name) if value.nil? && @object&.respond_to?(name) && !%w[password file].include?(type)
          opts = {name: field_name(name), id: field_id(name)}.merge(attrs)
          if type == "textarea"
            @view.element("textarea", value, opts)
          else
            opts[:value] = value unless value.nil? || type == "file"
            @view.tag.input(type: type, **opts)
          end
        end

        %w[text email password hidden file search url number].each do |type|
          define_method("#{type}_field") { |name, **attrs| field(name, type, **attrs) }
        end
        def text_area(name, **attrs) = field(name, "textarea", **attrs)
        def fields_for(name, record, &block) = @view.capture(Form.new(@view, record, field_name(name)), &block)
        def button(label = nil, **attrs, &block) = @view.button_tag(label, **attrs, &block)
        def submit(label = "Save", **attrs) = @view.tag.input(type: "submit", value: label, **attrs)
        def label(name, label = nil, **attrs, &block) = @view.label_tag(field_id(name), label, **attrs, &block)

        def check_box(name, options = {}, checked_value = "1", unchecked_value = "0")
          checked = options.key?(:checked) ? options[:checked] : @object&.respond_to?(name) && @object.public_send(name).to_s == checked_value
          @view.raw(@view.hidden_field_tag(field_name(name), unchecked_value) + field(name, "checkbox", value: checked_value, checked: checked, **options.except(:checked)))
        end

        def radio_button(name, value, **attrs)
          field(name, "radio", value: value, checked: @object&.respond_to?(name) && @object.public_send(name).to_s == value.to_s, **attrs)
        end

        def rich_text_area(name, **attrs, &block)
          value = attrs.delete(:value) || (@object.public_send(name) if @object&.respond_to?(name))
          @view.element("lexxy-editor", "", {name: field_name(name), id: field_id(name), value: value.to_s, class: "lexxy-content"}.merge(attrs), &block)
        end

        private

        def field_name(name) = @scope ? "#{@scope}[#{name}]" : name.to_s
        def field_id(name) = [@scope, name].compact.join("_")
      end
    end
  end
end
