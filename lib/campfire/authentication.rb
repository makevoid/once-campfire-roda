# frozen_string_literal: true

require "digest"

module Campfire
  class Authentication
    SESSION_TTL = 30 * 86_400
    DUMMY_DIGEST = BCrypt::Password.create(SecureRandom.hex(32), cost: 12).to_s.freeze

    def self.session_secret
      return ENV.fetch("SESSION_SECRET") if ENV["SESSION_SECRET"]
      raise "Set SESSION_SECRET to at least 64 random bytes in production" if ENV["RACK_ENV"] == "production"
      path = File.expand_path("../../storage/session-secret", __dir__)
      FileUtils.mkdir_p(File.dirname(path))
      begin
        File.write(path, SecureRandom.hex(64), mode: File::WRONLY | File::CREAT | File::EXCL, perm: 0o600)
      rescue Errno::EEXIST
      end
      File.read(path)
    end

    def initialize(db)
      @db = db
    end

    def authenticate(email, password, ip:)
      throttle!(ip)
      row = @db[:users].where(email_address: email.to_s.strip.downcase, status: 0).exclude(role: 2).first
      digest = row && row[:password_digest] || DUMMY_DIGEST
      valid = password.to_s.bytesize <= 72 && BCrypt::Password.new(digest).is_password?(password.to_s)
      raise Error.new("Invalid email or password", 401) unless row && valid
      User.new(row)
    rescue BCrypt::Errors::InvalidHash
      raise Error.new("Invalid email or password", 401)
    end

    def start(user, ip:, agent:)
      raw = SecureRandom.hex(32)
      now = Time.now.utc
      @db[:sessions].insert(user_id: user.id, token: Digest::SHA256.hexdigest(raw), ip_address: ip,
        user_agent: agent.to_s[0, 512], last_active_at: now, created_at: now, updated_at: now)
      raw
    end

    def resume(token, cache: nil, version: nil)
      return unless token.is_a?(String) && token.bytesize == 64
      now = Time.now.utc
      digest = Digest::SHA256.hexdigest(token)
      lookup = -> do
        @db[:sessions].join(:users, id: :user_id)
          .where(Sequel[:sessions][:token] => digest, Sequel[:users][:status] => 0)
          .where { Sequel[:sessions][:created_at] > now - SESSION_TTL }
          .select_all(:users).select_append(Sequel[:sessions][:id].as(:session_id), Sequel[:sessions][:last_active_at],
            Sequel[:sessions][:created_at].as(:session_created_at)).first
      end
      row = cache ? cache.record("session:#{digest}", version, &lookup) : lookup.call
      return unless row && row[:session_created_at] > now - SESSION_TTL
      if row[:last_active_at] < now - 3600
        @db[:sessions].where(id: row[:session_id]).where { last_active_at < now - 3600 }.update(last_active_at: now, updated_at: now)
      end
      User.new(row)
    end

    def terminate(token)
      @db[:sessions].where(token: Digest::SHA256.hexdigest(token.to_s)).delete
    end

    def bot(key)
      id, token = key.to_s.split("-", 2)
      return unless id&.match?(/\A\d+\z/) && token && token.bytesize >= 12
      row = @db[:users][id: id.to_i, bot_token: token, role: 2, status: 0]
      User.new(row) if row
    end

    private

    def throttle!(ip)
      key = Digest::SHA256.hexdigest(ip.to_s)
      window = Time.now.to_i / 180
      attempts = @db.transaction(mode: :immediate) do
        @db[:login_attempts].insert_conflict(target: :key, update: {
          attempts: Sequel.case({ {window: window} => Sequel[:attempts] + 1 }, 1), window: window
        }).insert(key: key, attempts: 1, window: window)
        @db[:login_attempts].where(key: key).get(:attempts)
      end
      raise Error.new("Too many sign-in attempts; try again in three minutes", 429) if attempts > 10
    end
  end
end
