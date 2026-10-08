# frozen_string_literal: true

require "net/http"
require "uri"
require "ipaddr"
require "resolv"
require "timeout"
require "web_push"
require "tempfile"
require "rack/mime"
require_relative "push_connections"

module Campfire
  class OutboundHTTP
    def initialize(connections: nil) = @connections = connections

    BLOCKED = %w[0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/3 2001:db8::/32].map { |net| IPAddr.new(net) }.freeze
    IPV6_GLOBAL = IPAddr.new("2000::/3")

    def self.public_address?(address)
      ip = IPAddr.new(address)
      ip = ip.native if ip.ipv4_mapped?
      return false if ip.ipv6? && !IPV6_GLOBAL.include?(ip)
      BLOCKED.none? { |net| net.include?(ip) }
    rescue IPAddr::InvalidAddressError
      false
    end

    def self.uri(value, https_only: false)
      uri = URI.parse(value.to_s)
      schemes = https_only ? ["https"] : %w[http https]
      raise Error, "Invalid endpoint URL" unless schemes.include?(uri.scheme) && uri.host && !uri.userinfo && !uri.fragment
      raise Error, "Endpoint URL is too long" if value.bytesize > 4096
      uri
    rescue URI::InvalidURIError
      raise Error, "Invalid endpoint URL"
    end

    def post(url, headers:, body:, allow_private: false, max_bytes: 100_000)
      uri = self.class.uri(url, https_only: !allow_private)
      addresses = Resolv.getaddresses(uri.hostname)
      raise Error, "Endpoint has no address" if addresses.empty?
      unless allow_private || addresses.all? { |address| self.class.public_address?(address) }
        raise Error, "Endpoint must resolve to a public address"
      end
      http = Net::HTTP.new(uri.hostname, uri.port, nil)
      # Pin the vetted address for the connection, retaining the hostname for
      # SNI and certificate validation. No second DNS lookup or redirects.
      http.ipaddr = addresses.first
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = http.read_timeout = http.write_timeout = 7
      request = Net::HTTP::Post.new(uri.request_uri, headers)
      request.body = body
      result = nil
      Timeout.timeout(10) do
        consume = proc do |response|
          data = +""
          response.read_body do |chunk|
            raise Error, "Endpoint response is too large" if data.bytesize + chunk.bytesize > max_bytes
            data << chunk
          end
          response.body = data
          result = response
        end
        if @connections && !allow_private
          @connections.request(http, request, &consume)
        else
          http.start { |connection| connection.request(request, &consume) }
        end
      end
      result
    end
  end

  class PushRequest < WebPush::Request
    CONNECTIONS = PushConnections.new
    HTTP = OutboundHTTP.new(connections: CONNECTIONS)
    at_exit { CONNECTIONS.shutdown }

    def perform
      PushPolicy.validate!(uri.to_s, resolve: false)
      response = HTTP.post(uri.to_s, headers: headers, body: body)
      verify_response(response)
    end
  end

  class JobQueue
    def initialize(db) = @db = db

    def enqueue(kind, payload, key: nil)
      now = Time.now.utc
      @db[:jobs].insert_conflict.insert(kind: kind, payload: JSON.generate(payload), dedup_key: key, available_at: now, created_at: now)
    end

    def claim
      now = Time.now.utc
      @db.transaction(mode: :immediate) do
        job = @db[:jobs].where { (available_at <= now) & (attempts < 8) }
          .where(Sequel.|({locked_at: nil}, Sequel[:locked_at] < now - 60)).order(:id).first
        next unless job
        token = SecureRandom.hex(16)
        @db[:jobs].where(id: job[:id]).update(locked_at: now, lock_token: token, attempts: job[:attempts] + 1)
        job.merge(lock_token: token, attempts: job[:attempts] + 1)
      end
    end

    def finish(job)
      @db[:jobs].where(id: job[:id], lock_token: job[:lock_token]).delete
    end

    def fail(job, error)
      # Store only the class; provider errors can include credentials or payloads.
      @db[:jobs].where(id: job[:id], lock_token: job[:lock_token]).update(locked_at: nil, lock_token: nil,
        available_at: Time.now.utc + [2**job[:attempts], 3600].min, last_error: error.class.name)
    end
  end

  class Delivery
    def initialize(container, http: OutboundHTTP.new, push_class: PushRequest)
      @container, @db, @repo, @service = container, container.db, container.repo, container.service
      @queue = JobQueue.new(@db)
      @http, @push_class = http, push_class
    end

    def work_once
      job = @queue.claim
      return false unless job
      begin
        payload = JSON.parse(job[:payload])
        case job[:kind]
        when "fanout" then fanout(payload.fetch("message_id"))
        when "webhook" then webhook(payload.fetch("message_id"), payload.fetch("user_id"))
        when "push" then push(payload.fetch("message_id"), payload.fetch("subscription_id"), badge: payload["badge"])
        when "push_test" then push_test(payload.fetch("subscription_id"))
        when "destroy_room" then destroy_room(payload.fetch("room_id"))
        else raise Error, "Unknown job kind"
        end
        @queue.finish(job)
      rescue StandardError => error
        @queue.fail(job, error)
        warn "Delivery job #{job[:id]} failed: #{error.class}"
      end
      true
    end

    def destroy_room(room_id)
      loop do
        ids = @db[:messages].where(room_id: room_id).order(:id).limit(100).select_map(:id)
        break if ids.empty?
        ids.each { |id| @db.transaction(mode: :immediate) { @db[:messages].where(id: id, room_id: room_id).delete } }
      end
      @db.transaction(mode: :immediate) { @db[:rooms].where(id: room_id).delete }
    end

    def fanout(message_id)
      message = @db[:messages][id: message_id]
      return unless message
      room = @db[:rooms][id: message[:room_id]]
      sender = @db[:users][id: message[:creator_id]]
      @db.transaction(mode: :immediate) do
        mention_ids = @service.mentioned_user_ids(message[:body])
        push_users = []
        recipients(message).each do |recipient|
          mention = mention_ids.include?(recipient[:id])
          if recipient[:role] == 2 && sender[:role] != 2 && (room[:type] == "Rooms::Direct" || mention) && @db[:webhooks].where(user_id: recipient[:id]).any?
            @queue.enqueue("webhook", {message_id: message_id, user_id: recipient[:id]}, key: "webhook:#{message_id}:#{recipient[:id]}")
          elsif eligible_push?(recipient, mention)
            push_users << recipient[:id]
          end
        end
        @db[:push_subscriptions].where(user_id: push_users).order(:id).each_slice(1000) do |batch|
          # Match the delivery batch's unread state, without counting once per
          # device. No payload or badge query is made for an empty audience.
          badges = @db[:memberships].where(user_id: batch.map { |sub| sub[:user_id] }).exclude(unread_at: nil)
            .group_and_count(:user_id).to_hash(:user_id, :count)
          batch.each do |subscription|
            id = subscription[:id]
            @queue.enqueue("push", {message_id: message_id, subscription_id: id, badge: badges.fetch(subscription[:user_id], 0)}, key: "push:#{message_id}:#{id}")
          end
        end
      end
    end

    def webhook(message_id, user_id)
      message = @db[:messages][id: message_id]
      return unless message
      recipient = recipients(message).find { |user| user[:id] == user_id && user[:role] == 2 }
      hook = @db[:webhooks][user_id: user_id]
      return unless recipient && hook
      room = @db[:rooms][id: message[:room_id]]
      return unless room[:type] == "Rooms::Direct" || mentioned?(message, recipient)
      sender = @db[:users][id: message[:creator_id]]
      payload = {user: {id: sender[:id], name: sender[:name]},
        room: {id: room[:id], name: room[:name], path: "/rooms/#{room[:id]}/#{user_id}-#{recipient[:bot_token]}/messages"},
        message: {id: message_id, body: {html: message[:body], plain: message[:plain_text].gsub("@#{recipient[:name]}", "").gsub(/\A\p{Space}+|\p{Space}+\z/, "")}, path: "/rooms/#{room[:id]}/@#{message_id}"}}
      # Like Rails Campfire, only administrators set bot URLs and may target
      # internal services. This exception never applies to push subscriptions.
      response = @http.post(hook[:url], headers: {"Content-Type" => "application/json"}, body: JSON.generate(payload), allow_private: true, max_bytes: Uploads::MAX_SIZE)
      return unless response.code == "200" && !response.body.to_s.empty?
      attributes = {"client_message_id" => "webhook-#{user_id}-#{message_id}"}
      if %w[text/plain text/html].include?(response.content_type)
        body = response.body.dup.force_encoding(Encoding::UTF_8)
        @service.post_message(User.new(recipient), room[:id], attributes.merge("body" => body))
      elsif extension = Rack::Mime::MIME_TYPES.key(response.content_type)
        Tempfile.create(["campfire-bot-", extension]) do |file|
          file.binmode
          file.write(response.body)
          file.flush
          @service.post_message(User.new(recipient), room[:id], attributes.merge("attachment" => {tempfile: file, filename: "attachment#{extension}"}))
        end
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      @service.post_message(User.new(recipient), room[:id], {"body" => "Failed to respond within 7 seconds", "client_message_id" => "webhook-#{user_id}-#{message_id}"}) if recipient && room
    end

    def push(message_id, subscription_id, badge: nil)
      return if ENV["VAPID_PRIVATE_KEY"].to_s.empty? || ENV["VAPID_PUBLIC_KEY"].to_s.empty?
      message = @db[:messages][id: message_id]
      subscription = @db[:push_subscriptions][id: subscription_id]
      return unless message && subscription
      recipient = recipients(message).find { |user| user[:id] == subscription[:user_id] }
      return unless recipient && eligible_push?(recipient, mentioned?(message, recipient))
      sender = @db[:users][id: message[:creator_id]]
      room = @db[:rooms][id: message[:room_id]]
      direct = room[:type] == "Rooms::Direct"
      deliver_push(subscription, title: direct ? sender[:name] : room[:name],
        body: direct ? message[:plain_text] : "#{sender[:name]}: #{message[:plain_text]}", path: "/rooms/#{room[:id]}", badge: badge)
    end

    def push_test(subscription_id)
      subscription = @db[:push_subscriptions][id: subscription_id]
      return unless subscription && @db[:users][id: subscription[:user_id], status: 0]
      deliver_push(subscription, title: "Campfire Test", body: SecureRandom.uuid, path: "/users/me/push_subscriptions")
    end

    def deliver_push(subscription, title:, body:, path:, badge: nil)
      return if ENV["VAPID_PRIVATE_KEY"].to_s.empty? || ENV["VAPID_PUBLIC_KEY"].to_s.empty?
      badge ||= @db[:memberships].where(user_id: subscription[:user_id]).exclude(unread_at: nil).count
      @push_class.new(message: JSON.generate(title: title, options: {body: body, icon: "/account/logo", data: {path: path, badge: badge}}),
        subscription: {endpoint: subscription[:endpoint], keys: {p256dh: subscription[:p256dh_key], auth: subscription[:auth_key]}},
        vapid: {subject: ENV.fetch("VAPID_SUBJECT", "mailto:admin@example.com"), public_key: ENV["VAPID_PUBLIC_KEY"], private_key: ENV["VAPID_PRIVATE_KEY"]}, urgency: "high").perform
    rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription
      @db[:push_subscriptions].where(id: subscription[:id]).delete
    end

    private

    def recipients(message)
      @db[:users].join(:memberships, user_id: :id).where(Sequel[:memberships][:room_id] => message[:room_id], Sequel[:users][:status] => 0)
        .exclude(Sequel[:users][:id] => message[:creator_id]).select_all(:users)
        .select_append(Sequel[:memberships][:involvement], Sequel[:memberships][:connected_at]).all
    end

    def mentioned?(message, user)
      @service.mentioned_user_ids(message[:body]).include?(user[:id])
    end

    def eligible_push?(user, mention)
      user[:role] != 2 && (user[:connected_at].nil? || user[:connected_at] < Time.now.utc - 60) &&
        (user[:involvement] == "everything" || (user[:involvement] == "mentions" && mention))
    end
  end
end
