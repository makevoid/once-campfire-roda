# frozen_string_literal: true
require_relative "test_helper"

class FetchMetadataTest < CampfireTest
  def credentials = {email_address: admin[:email_address], password: PASSWORD}

  def test_https_requires_same_origin_or_same_site_metadata
    header "Origin", "https://example.org"
    post "https://example.org/session", credentials.merge(authenticity_token: "legacy token")
    assert_equal 422, last_response.status
    assert_equal 0, db[:sessions].count
    %w[same-origin same-site].each do |site|
      header "Sec-Fetch-Site", site
      post "https://example.org/session", credentials
      assert_equal 302, last_response.status
    end
  end

  def test_cross_site_none_malformed_and_foreign_origins_are_rejected
    %w[http https].each do |scheme|
      %w[cross-site none garbage].each do |site|
        header "Sec-Fetch-Site", site
        post "#{scheme}://example.org/session", credentials
        assert_equal 422, last_response.status
      end
      header "Sec-Fetch-Site", "same-site"
      ["null", "https://foreign.example", "#{scheme}://example.org:9876"].each do |origin|
        header "Origin", origin
        post "#{scheme}://example.org/session", credentials
        assert_equal 422, last_response.status
      end
      header "Origin", nil
    end
    assert_equal 0, db[:sessions].count
  end

  def test_http_fallback_reads_and_method_override
    header "Origin", "http://example.org"
    post "/session", credentials
    assert_equal 302, last_response.status
    header "Sec-Fetch-Site", "cross-site"
    get "/rooms/#{room.id}"
    assert_equal 200, last_response.status
    post "/rooms/#{room.id}", {_method: "delete"}
    assert_equal 422, last_response.status
    assert repo.room(admin, room.id)
  end
end
