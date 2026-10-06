# frozen_string_literal: true
require_relative "test_helper"

class OpenGraphTest < Minitest::Test
  def resolver
    ->(host) { host == "private.test" ? ["127.0.0.1"] : ["93.184.216.34"] }
  end

  def test_extracts_metadata_and_checks_image_content_type
    calls = []
    transport = lambda do |uri, ip, method|
      calls << [uri.to_s, ip, method]
      if method == :head
        {code: 200, type: "image/png"}
      else
        {code: 200, type: "text/html", body: '<meta property="og:title" content="&lt;b&gt;Hello&lt;/b&gt;"><meta name="og:description" content="A story"><meta property="og:url" content="https://private.test/canonical"><meta property="og:image" content="https://public.test/photo.png">'}
      end
    end
    graph = Campfire::OpenGraph.new(resolver: resolver, transport: transport)
    assert_equal({"title" => "Hello", "description" => "A story", "url" => "https://public.test/story", "image" => "https://public.test/photo.png"}, graph.from_url("https://public.test/story"))
    assert_equal [:get, :head], calls.map(&:last)
    assert_equal ["93.184.216.34"], calls.map { |c| c[1] }.uniq
  end

  def test_private_targets_and_redirects_never_get_requested
    calls = []
    transport = lambda do |uri, _ip, _method|
      calls << uri.host
      {code: 302, location: "http://private.test/secrets"}
    end
    graph = Campfire::OpenGraph.new(resolver: resolver, transport: transport)
    assert_nil graph.from_url("http://private.test/")
    assert_empty calls
    assert_nil graph.from_url("https://public.test/")
    assert_equal ["public.test"], calls
  end

  def test_relative_redirects_are_revalidated_and_redirects_are_bounded
    count = 0
    transport = ->(*) { count += 1; {code: 302, location: "/next"} }
    graph = Campfire::OpenGraph.new(resolver: resolver, transport: transport)
    assert_nil graph.from_url("https://public.test/")
    assert_equal 10, count
  end

  def test_unsupported_documents_and_missing_required_metadata_are_ignored
    transport = ->(*) { {code: 200, type: "text/html", body: '<meta property="og:title" content="Only title">'} }
    graph = Campfire::OpenGraph.new(resolver: resolver, transport: transport)
    assert_nil graph.from_url("https://public.test/")
    assert_nil graph.from_url("https://public.test/file.mp4")
    assert_nil graph.from_url("file:///etc/passwd")
  end
end
