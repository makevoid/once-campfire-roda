# frozen_string_literal: true

require "openssl"
require "base64"

module Campfire
  # Purpose separation prevents an avatar or attachment token authorizing a login.
  class Tokens
    def initialize(secret)
      @key = OpenSSL::HMAC.digest("SHA256", secret, "campfire.signed-identifiers.v1")
    end

    def generate(value, purpose:, expires_in: nil, now: Time.now.to_i)
      data = {"value" => value, "purpose" => purpose.to_s}
      data["expires"] = now + expires_in if expires_in
      payload = Base64.urlsafe_encode64(JSON.generate(data), padding: false)
      "#{payload}--#{signature(payload)}"
    end

    def verify(token, purpose:, now: Time.now.to_i)
      return unless token.is_a?(String) && token.bytesize <= 4096
      payload, mac = token.split("--", 2)
      return unless mac&.bytesize == 64 && OpenSSL.fixed_length_secure_compare(mac, signature(payload))
      data = JSON.parse(Base64.urlsafe_decode64(payload))
      return unless data["purpose"] == purpose.to_s
      return if data["expires"] && data["expires"] <= now
      data["value"]
    rescue ArgumentError, JSON::ParserError, TypeError
      nil
    end

    private

    def signature(payload) = OpenSSL::HMAC.hexdigest("SHA256", @key, payload)
  end
end
