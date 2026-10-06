# frozen_string_literal: true

require "erubi/capture_block"
require "cgi/escape"
require "thread"

module Campfire
  module UI
    # Only explicitly trusted renderer output bypasses HTML escaping.
    class HTML < String
      def to_s = self
      def +(other) = HTML.new(super(other.is_a?(HTML) ? other : CGI.escapeHTML(other.to_s)))
    end

    class Buffer
      def initialize = @value = HTML.new
      def append=(value)
        @value << (value.is_a?(HTML) ? value : CGI.escapeHTML(value.to_s))
      end
      def literal=(value)
        @value << value
      end
      def <<(value)
        @value << value.to_s
        self
      end
      def |(value)
        self.append = value
        self
      end
      def to_s = @value
      def empty? = @value.empty?
    end

    class Engine
      ROOT = File.expand_path("../../../views/upstream", __dir__)
      attr_reader :templates

      def initialize(root: ROOT)
        @templates = Module.new
        @compiled = {}
        @mutex = Mutex.new
        @paths = Dir[File.join(root, "**/*.html.erb")].to_h do |path|
          [path.delete_prefix("#{root}/").delete_suffix(".html.erb"), path]
        end.freeze
      end

      def render(view, name, locals = {}, partial: false, &block)
        keys = locals.keys.map(&:to_sym).sort
        # Resolve paths and validate local names once per compiled template shape.
        key = [name.to_s, partial, keys]
        method = @compiled[key] || @mutex.synchronize do
          @compiled[key] ||= begin
            raise ArgumentError, "Invalid template locals" unless keys.all? { |local| local.to_s.match?(/\A[a-z_]\w*\z/) }
            key[0] = key[0].dup.freeze
            compile(resolve(name, partial), keys)
          end
        end
        view.extend(@templates) unless view.is_a?(@templates)
        view.public_send(method, locals, &block)
      end

      def resolve(name, partial)
        name = name.to_s
        raise ArgumentError, "Invalid template" unless name.match?(%r{\A[a-zA-Z0-9_/-]+\z}) && !name.split("/").include?("..")
        folder, base = File.split(name)
        base = "_#{base}" if partial && !base.start_with?("_")
        key = folder == "." ? base : "#{folder}/#{base}"
        @paths[key] || raise(Error.new("Template not found: #{name}", 500))
      end

      private

      def compile(path, keys)
        code = Erubi::CaptureBlockEngine.new(File.read(path), filename: path,
          bufvar: "@output_buffer", escape: true, preamble: "", postamble: "").src
        name = "render_template_#{@compiled.length}"
        assignments = keys.map { |key| "#{key} = local_assigns[:#{key}]" }.join("\n")
        @templates.module_eval(<<~RUBY, path, 1)
          def #{name}(local_assigns = {}, &block)
            previous = @output_buffer
            @output_buffer = Campfire::UI::Buffer.new
            #{assignments}
            #{code}
            @output_buffer.to_s
          ensure
            @output_buffer = previous
          end
        RUBY
        name
      end
    end
  end
end
