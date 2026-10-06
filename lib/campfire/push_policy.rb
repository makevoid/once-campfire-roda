# frozen_string_literal: true
module Campfire
  module PushPolicy
    HOSTS = %w[jmt17.google.com fcm.googleapis.com updates.push.services.mozilla.com web.push.apple.com notify.windows.com].freeze

    def self.validate!(endpoint, resolver: Resolv.method(:getaddresses), resolve: true)
      uri = OutboundHTTP.uri(endpoint, https_only: true)
      host = uri.hostname.downcase
      raise Error, "Push endpoint must use HTTPS port 443" unless uri.port == 443
      raise Error, "Unknown push service" unless HOSTS.any? { |allowed| host == allowed || host.end_with?(".#{allowed}") }
      if resolve
        addresses = resolver.call(host)
        raise Error, "Push service must resolve to public addresses" if addresses.empty? || !addresses.all? { |address| OutboundHTTP.public_address?(address) }
      end
      uri
    end
  end
end
