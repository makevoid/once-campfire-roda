# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/campfire/ui/engine"
require_relative "../lib/campfire/ui/html_helpers"

class RenderingTest < Minitest::Test
  class View
    include Campfire::UI::HTMLHelpers
    def initialize(engine)
      @engine, @contents = engine, {}
    end
    def partial(name, **locals) = @engine.render(self, name, locals, partial: true)
  end

  def test_erubi_captures_nested_blocks_and_escapes_untrusted_values
    with_templates("page" => '<%= tag.section(class: "outer") do %><%= tag.b do %><%= value %><% end %><%= partial("item", value: value) %><% end %>',
      "_item" => '<i title="<%= value %>"><%= value %></i>') do |engine, view|
      assert_equal '<section class="outer"><b>&lt;script&gt;&quot;&amp;</b><i title="&lt;script&gt;&quot;&amp;">&lt;script&gt;&quot;&amp;</i></section>',
        engine.render(view, "page", {value: '<script>"&'})
    end
  end

  def test_compiled_methods_are_reused_without_caching_request_output
    with_templates("page" => '<%= value %>') do |engine, view|
      assert_equal "one", engine.render(view, "page", {value: "one"})
      File.write(File.join(@templates, "page.html.erb"), "Changed after compilation")
      assert_equal "two", engine.render(view, "page", {value: "two"})
    end
  end

  def test_raw_output_requires_explicit_trust_and_buffers_recover_from_errors
    with_templates("page" => '<%= raw("<b>trusted</b>") %><%= value %>', "bad" => '<% raise "failed" %>') do |engine, view|
      assert_raises(RuntimeError) { engine.render(view, "bad") }
      assert_equal '<b>trusted</b>&lt;i&gt;', engine.render(view, "page", {value: "<i>"})
      assert_nil view.instance_variable_get(:@output_buffer)
      assert_raises(ArgumentError) { engine.render(view, "../page") }
    end
  end

  def test_roda_bundle_and_runtime_have_no_rails_dependencies
    rails_gems = /\A(?:rails|railties|activesupport|activemodel|activerecord|activejob|activestorage|actionview|actionpack|actioncable|actionmailer|actionmailbox|actiontext)(?:-|\z)/
    assert_empty Bundler.load.specs.map(&:name).grep(rails_gems)
    assert_empty Gem.loaded_specs.keys.grep(rails_gems)
    refute Object.const_defined?(:ActiveSupport)
    refute Object.const_defined?(:ActionView)
  end

  def test_shared_compiled_templates_keep_locals_and_partial_variants_separate
    with_templates("page" => '<%= first %>:<%= second %>', "_page" => '<b><%= first %></b>') do |engine, _|
      view_class = Class.new(View) { include engine.templates }
      first, second = view_class.new(engine), view_class.new(engine)
      assert_equal "one:two", engine.render(first, "page", {first: "one", second: "two"})
      File.write(File.join(@templates, "page.html.erb"), "Changed after compilation")
      assert_equal "&lt;three&gt;:four", engine.render(second, "page", {second: "four", first: "<three>"})
      assert_equal "<b>five</b>", engine.render(first, "page", {first: "five"}, partial: true)
      assert_raises(ArgumentError) { engine.render(second, "page", {"bad;key": "six"}) }
      assert_raises(ArgumentError) { engine.render(second, "../page", {first: "six"}) }
    end
  end

  private

  def with_templates(templates)
    Dir.mktmpdir("campfire-templates-") do |directory|
      @templates = directory
      templates.each { |name, source| File.write(File.join(directory, "#{name}.html.erb"), source) }
      engine = Campfire::UI::Engine.new(root: directory)
      yield engine, View.new(engine)
    end
  end
end
