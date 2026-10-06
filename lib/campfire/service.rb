# frozen_string_literal: true

module Campfire
  class Service
    attr_reader :repo, :db
    def initialize(repo, uploads)
      @repo, @db, @uploads = repo, repo.db, uploads
    end

    def setup(attributes)
      digest = password(attributes["password"])
      db.transaction(mode: :immediate) do
        raise Error.new("Campfire is already configured", 409) if repo.account
        now = Time.now.utc
        db[:accounts].insert(name: "Campfire", join_code: SecureRandom.hex(16), created_at: now, updated_at: now)
        user = create_user(attributes, role: 1, digest: digest)
        create_room(user, {"name" => "All Talk"}, type: "Rooms::Open")
        user
      end
    end

    def join(code, attributes)
      digest = password(attributes["password"])
      db.transaction(mode: :immediate) do
        raise Error.new("Invalid invitation", 404) unless repo.account&.fetch(:join_code) == code
        create_user(attributes, digest: digest)
      end
    end

    def create_user(attributes, role: 0, digest: nil)
      now = Time.now.utc
      email = attributes["email_address"].to_s.strip.downcase
      raise Error, "Enter a valid email address" if role != 2 && !email.match?(/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/)
      name = required(attributes["name"], "Name", 100)
      id = db[:users].insert(name: name, email_address: role == 2 ? nil : email,
        password_digest: digest, role: role, bot_token: role == 2 ? SecureRandom.hex(24) : nil, created_at: now, updated_at: now)
      room_ids = db[:rooms].where(type: "Rooms::Open").select_map(:id)
      room_ids.each { |room_id| grant(room_id, [id]) }
      repo.user(id)
    end

    def update_profile(actor, attributes)
      changes = {name: required(attributes["name"], "Name", 100), bio: attributes["bio"].to_s[0, 2000], updated_at: Time.now.utc}
      if attributes["email_address"]
        email = attributes["email_address"].strip.downcase
        raise Error, "Enter a valid email address" unless email.match?(/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/)
        changes[:email_address] = email
      end
      changes[:password_digest] = password(attributes["password"]) unless attributes["password"].to_s.empty?
      db.transaction(mode: :immediate) do
        db[:users].where(id: actor.id).update(changes)
        db[:sessions].where(user_id: actor.id).delete if changes[:password_digest]
      end
    end

    def create_room(actor, attributes, type:, user_ids: [])
      db.transaction(mode: :immediate) do
        restricted = JSON.parse(repo.account.fetch(:settings) || "{}")["restrict_room_creation_to_administrators"]
        raise Error.new("Only administrators can create rooms", 403) if restricted && !actor.administrator? && type != "Rooms::Direct"
        raise Error, "Invalid room type" unless %w[Rooms::Open Rooms::Closed Rooms::Direct].include?(type)
        ids = active_ids(user_ids + [actor.id])
        now = Time.now.utc
        direct_key = ids.sort.join(",") if type == "Rooms::Direct"
        existing = db[:rooms][direct_key: direct_key] if direct_key
        return Room.new(existing) if existing
        id = db[:rooms].insert(name: type == "Rooms::Direct" ? nil : required(attributes["name"], "Room name", 100),
          creator_id: actor.id, type: type, direct_key: direct_key, created_at: now, updated_at: now)
        ids = db[:users].where(status: 0).select_map(:id) if type == "Rooms::Open"
        grant(id, ids, type == "Rooms::Direct" ? "everything" : "mentions")
        repo.room(actor, id)
      end
    end

    def update_room(actor, room_id, attributes, type:, user_ids: [])
      db.transaction(mode: :immediate) do
        room = repo.room(actor, room_id)
        administer!(actor, room)
        raise Error, "Direct room participants and type cannot be changed" if room.direct?
        raise Error, "Invalid room type" unless %w[Rooms::Open Rooms::Closed].include?(type)
        db[:rooms].where(id: room.id).update(name: required(attributes["name"], "Room name", 100), type: type, updated_at: Time.now.utc)
        ids = type == "Rooms::Open" ? db[:users].where(status: 0).select_map(:id) : active_ids(user_ids + [actor.id])
        db[:memberships].where(room_id: room.id).exclude(user_id: ids).delete
        grant(room.id, ids)
      end
    end

    def delete_room(actor, room_id, direct_only: false)
      db.transaction(mode: :immediate) do
        room = repo.room(actor, room_id)
        raise Error.new("Room not found", 404) if direct_only && !room.direct?
        administer!(actor, room) unless direct_only
        db[:rooms].where(id: room.id).delete
      end
    end

    def post_message(actor, room_id, attributes)
      content = Content.new(attributes["body"])
      upload = @uploads.stage(attributes["attachment"])
      raise Error, "Write a message or attach a file" if content.text.empty? && !upload
      result = db.transaction(mode: :immediate) do
        room = repo.room(actor, room_id)
        now = Time.now.utc
        client_id = attributes["client_message_id"].to_s
        client_id = SecureRandom.uuid if client_id.empty?
        raise Error, "Invalid client message ID" if client_id.bytesize > 128
        existing = db[:messages][room_id: room.id, creator_id: actor.id, client_message_id: client_id]
        if existing
          @uploads.discard(upload)
          next existing
        end
        id = db[:messages].insert(room_id: room.id, creator_id: actor.id, client_message_id: client_id,
          body: content.html, plain_text: content.text.empty? ? upload[:filename] : content.text, created_at: now, updated_at: now)
        db[:attachments].insert(upload.merge(message_id: id, created_at: now)) if upload
        touch_room(room.id, now)
        db[:memberships].where(room_id: room.id).exclude(user_id: actor.id).exclude(involvement: "invisible")
          .where(Sequel.|({connected_at: nil}, Sequel[:connected_at] < now - 60)).update(unread_at: now, updated_at: now)
        event(room.id, id, "create", now)
        JobQueue.new(db).enqueue("fanout", {message_id: id}, key: "fanout:#{id}")
        repo.message(room.id, id)
      end
      result
    rescue StandardError
      @uploads.discard(upload)
      raise
    end

    def edit_message(actor, room_id, id, attributes)
      content = Content.new(attributes["body"])
      db.transaction(mode: :immediate) do
        room = repo.room(actor, room_id)
        message = repo.message(room.id, id)
        administer!(actor, message)
        attachment = db[:attachments][message_id: id]
        raise Error, "Write a message or attach a file" if content.text.empty? && !attachment
        now = Time.now.utc
        db[:messages].where(id: id).update(body: content.html, plain_text: content.text.empty? ? attachment[:filename] : content.text, updated_at: now)
        touch_room(room.id, now)
        event(room.id, id, "update", now)
        repo.message(room.id, id)
      end
    end

    def delete_message(actor, room_id, id)
      db.transaction(mode: :immediate) do
        room = repo.room(actor, room_id)
        administer!(actor, repo.message(room.id, id))
        db[:messages].where(id: id).delete
        now = Time.now.utc
        touch_room(room.id, now)
        event(room.id, id, "delete", now)
      end
    end

    def boost(actor, room_id, message_id, content)
      db.transaction(mode: :immediate) do
        room = repo.room(actor, room_id)
        repo.message(room.id, message_id)
        now = Time.now.utc
        id = db[:boosts].insert(message_id: message_id, booster_id: actor.id, content: required(content, "Boost", 16), created_at: now, updated_at: now)
        db[:messages].where(id: message_id).update(updated_at: now)
        event(room.id, message_id, "update", now)
        id
      end
    end

    def unboost(actor, room_id, message_id, id)
      db.transaction(mode: :immediate) do
        repo.room(actor, room_id)
        repo.message(room_id, message_id)
        boost = db[:boosts][id: id, message_id: message_id] || raise(Error.new("Boost not found", 404))
        raise Error.new("Forbidden", 403) unless boost[:booster_id] == actor.id
        db[:boosts].where(id: id).delete
        now = Time.now.utc
        db[:messages].where(id: message_id).update(updated_at: now)
        event(room_id, message_id, "update", now)
      end
    end

    def involvement(actor, room_id, value)
      raise Error, "Invalid notification setting" unless %w[invisible nothing mentions everything].include?(value)
      repo.room(actor, room_id)
      db[:memberships].where(room_id: room_id, user_id: actor.id).update(involvement: value, updated_at: Time.now.utc)
    end

    def heartbeat(actor, room_id)
      repo.room(actor, room_id)
      now = Time.now.utc
      db[:memberships].where(room_id: room_id, user_id: actor.id).update(connected_at: now, connections: 1, unread_at: nil)
    end

    def record_search(actor, query)
      query = query.to_s.scan(/[[:word:]]+/).join(" ")[0, 500]
      return if query.empty?
      now = Time.now.utc
      db.transaction(mode: :immediate) do
        db[:searches].insert_conflict(target: [:user_id, :query], update: {updated_at: now})
          .insert(user_id: actor.id, query: query, created_at: now, updated_at: now)
        recent = db[:searches].where(user_id: actor.id).reverse_order(:updated_at, :id).limit(10).select(:id)
        db[:searches].where(user_id: actor.id).exclude(id: recent).delete
      end
    end

    def manage_user(actor, user_id, action, role: nil)
      admin!(actor)
      db.transaction(mode: :immediate) do
        target = repo.user(user_id)
        if target.administrator? && (action != :role || role != "administrator") && db[:users].where(role: 1, status: 0).count <= 1
          raise Error, "Keep at least one active administrator"
        end
        now = Time.now.utc
        case action
        when :role
          raise Error, "Invalid role" unless %w[member administrator].include?(role) && !target.bot?
          db[:users].where(id: user_id).update(role: role == "administrator" ? 1 : 0, updated_at: now)
        when :deactivate, :ban
          if action == :ban
            db[:sessions].where(user_id: user_id).exclude(ip_address: [nil, ""]).select_map(:ip_address).uniq.each do |ip|
              db[:bans].insert(user_id: user_id, ip_address: ip, created_at: now, updated_at: now)
            end
            db[:messages].where(creator_id: user_id).select(:id, :room_id).each { |m| event(m[:room_id], m[:id], "delete", now) }
            db[:messages].where(creator_id: user_id).delete
          else
            db[:memberships].where(user_id: user_id, room_id: db[:rooms].exclude(type: "Rooms::Direct").select(:id)).delete
          end
          db[:sessions].where(user_id: user_id).delete
          db[:searches].where(user_id: user_id).delete
          db[:push_subscriptions].where(user_id: user_id).delete
          db[:users].where(id: user_id).update(status: action == :ban ? 2 : 1, updated_at: now)
        when :unban
          db[:bans].where(user_id: user_id).delete
          db[:users].where(id: user_id).update(status: 0, updated_at: now)
        end
      end
    end

    def admin!(actor)
      raise Error.new("Administrator access required", 403) unless actor.administrator?
    end

    def update_bot(actor, id, attributes)
      admin!(actor)
      bot = repo.user(id)
      raise Error.new("Bot not found", 404) unless bot.bot?
      url = attributes["webhook_url"].to_s.strip
      OutboundHTTP.uri(url) unless url.empty?
      db.transaction(mode: :immediate) do
        now = Time.now.utc
        db[:users].where(id: id).update(name: required(attributes["name"], "Bot name", 100), updated_at: now)
        if url.empty?
          db[:webhooks].where(user_id: id).delete
        else
          db[:webhooks].insert_conflict(target: :user_id, update: {url: url, updated_at: now}).insert(user_id: id, url: url, created_at: now, updated_at: now)
        end
      end
    end

    def subscribe(actor, attributes, agent:)
      endpoint = attributes["endpoint"].to_s
      OutboundHTTP.uri(endpoint, https_only: true)
      keys = attributes["keys"] || {}
      p256dh, auth = keys["p256dh"].to_s, keys["auth"].to_s
      raise Error, "Invalid push keys" unless Base64.urlsafe_decode64(p256dh).bytesize == 65 && Base64.urlsafe_decode64(auth).bytesize == 16
      db.transaction(mode: :immediate) do
        existing = db[:push_subscriptions][endpoint: endpoint]
        raise Error.new("Subscription belongs to another user", 409) if existing && existing[:user_id] != actor.id
        raise Error, "Too many devices" if !existing && db[:push_subscriptions].where(user_id: actor.id).count >= 20
        now = Time.now.utc
        values = {p256dh_key: p256dh, auth_key: auth, user_agent: agent.to_s[0, 200], updated_at: now}
        if existing
          db[:push_subscriptions].where(id: existing[:id]).update(values)
          existing[:id]
        else
          db[:push_subscriptions].insert(values.merge(user_id: actor.id, endpoint: endpoint, created_at: now))
        end
      end
    rescue ArgumentError
      raise Error, "Invalid push keys"
    end

    def administer!(actor, record)
      raise Error.new("Forbidden", 403) unless actor.can_administer?(record)
    end

    def required(value, label, length)
      value = value.to_s.strip
      raise Error, "#{label} must contain 1–#{length} characters" if value.empty? || value.length > length
      value
    end

    private

    def password(value)
      raise Error, "Password must contain 12–72 bytes" unless (12..72).cover?(value.to_s.bytesize)
      BCrypt::Password.create(value, cost: 12).to_s
    end

    def active_ids(ids)
      raise Error, "Too many participants" if ids.length > 1000
      ids = ids.map { |id| repo.integer(id) }.uniq
      found = db[:users].where(id: ids, status: 0).select_map(:id)
      raise Error, "Unknown or inactive participant" unless found.sort == ids.sort
      found
    end

    def grant(room_id, ids, involvement = "mentions")
      now = Time.now.utc
      rows = ids.map { |id| {room_id: room_id, user_id: id, involvement: involvement, created_at: now, updated_at: now} }
      db[:memberships].insert_conflict.multi_insert(rows) unless rows.empty?
    end

    def touch_room(id, now)
      db[:rooms].where(id: id).update(updated_at: now)
    end

    def event(room_id, message_id, kind, now)
      db[:events].insert(room_id: room_id, message_id: message_id, kind: kind, created_at: now)
    end
  end
end
