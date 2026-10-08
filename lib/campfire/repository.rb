# frozen_string_literal: true

module Campfire
  class Repository
    PAGE_SIZE = 40
    attr_reader :db

    def initialize(db)
      @db = db
      @presentation = db[:messages].join(:users, id: :creator_id)
        .select_all(:messages).select_append(Sequel[:users][:name].as(:creator_name), Sequel[:users][:role].as(:creator_role))
    end

    def account = db[:accounts].first

    def user(id)
      row = db[:users][id: id]
      raise Error.new("User not found", 404) unless row
      User.new(row)
    end

    def room(user, id, cache: nil, version: nil)
      lookup = -> do
        db[:rooms].join(:memberships, room_id: :id)
          .where(Sequel[:rooms][:id] => id, Sequel[:memberships][:user_id] => user.id)
          .select_all(:rooms).select_append(Sequel[:memberships][:involvement], Sequel[:memberships][:unread_at]).first
      end
      row = cache ? cache.record("room:#{user.id}:#{id}", version, &lookup) : lookup.call
      raise Error.new("Room not found", 404) unless row
      Room.new(row)
    end

    def room_name(room, user)
      return room[:name] unless room.direct?
      names = db[:users].join(:memberships, user_id: :id).where(Sequel[:memberships][:room_id] => room.id)
        .exclude(Sequel[:users][:id] => user.id).order(Sequel[:users][:name]).select_map(Sequel[:users][:name])
      names.empty? ? user[:name] : names.join(", ")
    end

    def message(room_id, id)
      db[:messages][room_id: room_id, id: id] || raise(Error.new("Message not found", 404))
    end

    # The timestamp + id tuple gives a stable boundary even when bulk inserts
    # have identical timestamps. No OFFSET walks, and cursors stay room-scoped.
    def messages(room_id, before: nil, after: nil, around: nil)
      if around
        anchor = message(room_id, integer(around))
        return present(fetch_page(room_id, anchor, :before) + [anchor] + fetch_page(room_id, anchor, :after))
      end
      anchor = before || after
      anchor = message(room_id, integer(anchor)) if anchor
      present(fetch_page(room_id, anchor, after ? :after : :before))
    end

    def search(user, query)
      words = query.to_s.scan(/[[:word:]]+/).first(32)
      return Page.new([]) if words.empty?
      terms = words.map { |word| %Q{"#{word}"} }.join(" ")
      # FTS rowid order allows SQLite to stop after the newest 100 matches;
      # membership filtering occurs before LIMIT so private messages never leak.
      rows = db.fetch(<<~SQL, terms, user.id).all.reverse!
        SELECT messages.*, users.name AS creator_name, users.role AS creator_role FROM message_search_index
        JOIN messages ON messages.id = message_search_index.rowid
        JOIN users ON users.id = messages.creator_id
        WHERE message_search_index MATCH ?
          AND messages.room_id IN (SELECT room_id FROM memberships WHERE user_id = ?)
        ORDER BY message_search_index.rowid DESC LIMIT 100
      SQL
      present(rows)
    end

    def sidebar(user)
      memberships = db[:memberships].join(:rooms, id: :room_id)
        .where(Sequel[:memberships][:user_id] => user.id)
        .select_all(:rooms).select_append(Sequel[:memberships][:unread_at], Sequel[:memberships][:involvement])
        .order(Sequel.function(:lower, Sequel[:rooms][:name])).all
      direct, shared = memberships.partition { |m| m[:type] == "Rooms::Direct" }
      ids = direct.map { |m| m[:id] }
      # Hidden direct rooms still exclude their participants from suggestions,
      # matching Rails. Visibility only controls the rendered room lists.
      direct.reject! { |m| m[:involvement] == "invisible" }
      shared.reject! { |m| m[:involvement] == "invisible" }
      direct.sort_by! { |m| m[:updated_at] }.reverse!
      people = ids.empty? ? [] : db[:memberships].join(:users, id: :user_id)
        .where(room_id: ids).select(:room_id, :user_id, :name).all
      names = people.reject { |p| p[:user_id] == user.id }.group_by { |p| p[:room_id] }
      direct.each { |m| m[:name] = names.fetch(m[:id], []).map { |p| p[:name] }.join(", "); m[:name] = user[:name] if m[:name].empty? }
      # Rails appends the current user after uniquing DM participants. Preserve
      # that count too: an existing DM consumes an extra placeholder slot.
      excluded = people.map { |p| p[:user_id] }.uniq + [user.id]
      limit = [20 - excluded.length, 0].max
      placeholders = limit.zero? ? [] : db[:users].where(status: 0).exclude(id: excluded).order(:created_at).limit(limit).select(:id, :name).all
      { shared: shared, direct: direct, people: placeholders }
    end

    def present(rows)
      return Page.new([]) if rows.empty?
      # One join fetches all creators, followed by two bounded bulk queries.
      # There is no per-message query or per-message Sequel model allocation.
      ids = rows.map { |m| m[:id] }
      messages = if rows.all? { |row| row.key?(:creator_name) }
        rows
      else
        indexed = @presentation.where(Sequel[:messages][:id] => ids).all.to_h { |m| [m[:id], m] }
        ids.filter_map { |id| indexed[id] }
      end
      boosts = db[:boosts].join(:users, id: :booster_id).where(message_id: ids)
        .select_all(:boosts).select_append(Sequel[:users][:name].as(:booster_name)).order(Sequel[:boosts][:id]).all.group_by { |b| b[:message_id] }
      attachments = db[:attachments].where(message_id: ids).all.group_by { |a| a[:message_id] }
      Page.new(messages, boosts: boosts, attachments: attachments)
    end

    def integer(value)
      Integer(value.to_s, 10)
    rescue ArgumentError, TypeError
      raise Error.new("Invalid identifier", 400)
    end

    private

    def fetch_page(room_id, anchor, direction)
      dataset = @presentation.where(Sequel[:messages][:room_id] => room_id)
      if anchor
        operator = direction == :after ? ">" : "<"
        dataset = dataset.where(Sequel.lit("(messages.created_at, messages.id) #{operator} (?, ?)", anchor[:created_at], anchor[:id]))
      end
      if direction == :after
        dataset.order(Sequel[:messages][:created_at], Sequel[:messages][:id]).limit(PAGE_SIZE).all
      else
        dataset.reverse_order(Sequel[:messages][:created_at], Sequel[:messages][:id]).limit(PAGE_SIZE).all.reverse!
      end
    end
  end
end
