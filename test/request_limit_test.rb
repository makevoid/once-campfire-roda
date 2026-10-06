# frozen_string_literal: true
require_relative "test_helper"

class RequestLimitTest < CampfireTest
  def test_declared_large_body_is_rejected_before_parameter_parsing
    post "/session", "short", {"CONTENT_LENGTH" => (Campfire::RequestLimit::MAX_BYTES + 1).to_s}
    assert_equal 413, last_response.status
    assert_equal "Request too large", last_response.body
  end

  def test_streamed_body_without_length_is_bounded
    io = Campfire::RequestLimit::Input.new(StringIO.new("x" * (Campfire::RequestLimit::MAX_BYTES + 1)))
    assert_raises(Campfire::RequestLimit::TooLarge) { io.read }
  end

  def test_limited_input_supports_rack_reads_and_rewinds
    io = Campfire::RequestLimit::Input.new(StringIO.new("hello\nworld"))
    assert_equal "hello\n", io.gets
    buffer = +""
    assert_equal "wor", io.read(3, buffer)
    assert_equal "wor", buffer
    assert_equal "ld", io.read
    io.rewind
    assert_equal "hello\nworld", io.read
  end
end
