# frozen_string_literal: true

module Campfire
  # Matches Campfire's header-only browser write protection. Check after method
  # override and after the separately authenticated bot API branch.
  module FetchMetadata
    private

    def check_browser_write!
      return if %w[GET HEAD OPTIONS].include?(request.request_method)

      site = request.env["HTTP_SEC_FETCH_SITE"]
      origin = request.env["HTTP_ORIGIN"]
      valid_site = %w[same-origin same-site].include?(site) || (site.nil? && !request.ssl?)
      valid_origin = origin.nil? || origin == request.base_url
      raise Error.new("Invalid browser request origin", 422) unless valid_site && valid_origin
    end
  end
end
