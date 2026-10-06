# frozen_string_literal: true

module Campfire
  module UI
    module Assets
      MANIFEST = JSON.parse(File.read(File.expand_path("../../../public/assets/.manifest.json", __dir__))).freeze
      PATHS = MANIFEST.transform_values { |entry| "/assets/#{entry.fetch('digested_path')}".freeze }.freeze
      IMPORTS = begin
        names = {
          "application" => "application.js", "@hotwired/stimulus" => "stimulus.min.js",
          "@hotwired/stimulus-loading" => "stimulus-loading.js", "@hotwired/turbo-rails" => "turbo.js",
          "@rails/actioncable" => "actioncable.esm.js", "@rails/request.js" => "@rails--request.js",
          "lexxy" => "lexxy.js", "highlight.js" => "highlight.js/core.js"
        }
        MANIFEST.each_key do |name|
          if name.match?(%r{\A(?:initializers|lib|channels|controllers|helpers|models|languages)/.*\.js\z})
            names[name.delete_suffix(".js").delete_suffix("/index")] = name
          end
        end
        names.transform_values { |name| "/assets/#{MANIFEST.fetch(name).fetch('digested_path')}" }.freeze
      end
      IMPORTMAP = JSON.generate(imports: IMPORTS).gsub("<", '\\u003c').freeze
      STYLESHEETS = MANIFEST.keys.grep(/\.css\z/).sort.freeze

      def asset_path(source)
        return "/attachments/#{source.file.id}?variant=#{source.name}" if source.is_a?(Variant)
        value = source.to_s
        return value if value.start_with?("/", "https://", "http://", "data:")
        PATHS.fetch(value)
      end

      def stylesheet_link_tag(*, **attrs)
        safe_join(STYLESHEETS.map { |name| tag.link(rel: "stylesheet", href: asset_path(name), **attrs) }, "\n")
      end

      def javascript_importmap_tags
        safe_join([
          tag.script(raw(IMPORTMAP), type: "importmap", nonce: @nonce, "data-turbo-track": "reload"),
          tag.script(raw('import "application"'), type: "module", nonce: @nonce)
        ], "\n")
      end

      def avatar_url(user) = "/users/#{user.avatar_token}/avatar?v=#{epoch(user.updated_at)}"
      def account_logo_url(size: nil) = "/account/logo?v=#{epoch(current.account&.updated_at || Time.at(0))}#{'&size=small' if size == :small}"
    end
  end
end
