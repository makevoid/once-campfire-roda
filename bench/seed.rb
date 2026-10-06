#!/usr/bin/env ruby
# frozen_string_literal: true
require "bundler/setup"
require "optparse"
require_relative "../lib/campfire"

module Campfire
  class BenchmarkSeed
    def self.create(directory, messages: 2000, users: 100)
      raise ArgumentError, "Need at least 100 messages and 3 users" unless messages >= 100 && users >= 3
      directory = File.expand_path(directory)
      path = File.join(directory, "campfire.sqlite3")
      raise "Refusing to replace #{path}; choose a fresh seed directory" if File.exist?(path)
      db = Database.connect(path: path)
      Database.migrate(db)
      container = Container.new(db: db, upload_root: File.join(directory, "files"))
      service = container.service
      password = "benchmark-fixture-password"
      now = Time.utc(2026, 10, 4, 12)
      digest = BCrypt::Password.create(password, cost: 12).to_s
      db.transaction do
        db[:accounts].insert(name: "Benchmark Campfire", join_code: "benchmark-fixture-invite", settings: "{}", created_at: now, updated_at: now)
        people = users.times.map do |i|
          service.create_user({"name" => i.zero? ? "David" : "Person #{i}", "email_address" => i.zero? ? "david@example.test" : "person#{i}@example.test"}, role: i.zero? ? 1 : 0, digest: digest)
        end
        admin = people.first
        room = service.create_room(admin, {"name" => "Watercooler"}, type: "Rooms::Open")
        11.times { |i| service.create_room(admin, {"name" => "Project #{i}"}, type: "Rooms::Open") }
        8.times { |i| service.create_room(admin, {}, type: "Rooms::Direct", user_ids: [people[i + 1].id]) } if users >= 9
        batch = messages.times.map do |i|
          body = i.even? ? "Anyone up for coffee? Batch #{i}. A conversation with <strong>the team</strong>." : "Project update #{i}: this is a realistic message with enough text to exercise rendering."
          {room_id: room.id, creator_id: people[i % people.length].id, client_message_id: "bench-#{i}", body: "<p>#{body}</p>",
            plain_text: body.gsub(/<[^>]+>/, ""), created_at: now + i, updated_at: now + i}
        end
        batch.each_slice(500) { |slice| db[:messages].multi_insert(slice) }
        db[:messages].where(Sequel.lit("id % 5 = 0")).select(:id).each do |message|
          db[:boosts].insert(message_id: message[:id], booster_id: admin.id, content: "☕", created_at: now, updated_at: now)
        end
        labels = {"fixture" => "campfire-roda-benchmark-v1", "emails.david" => admin[:email_address], "passwords.all" => password,
          "rooms.watercooler" => room.id, "messages.busy_060" => messages - 40, "messages.count" => messages, "users.count" => users}
        File.write(File.join(directory, "labels.json"), JSON.pretty_generate(labels) + "\n")
      end
      db.run("ANALYZE")
      db.run("PRAGMA wal_checkpoint(TRUNCATE)")
      db.disconnect
      directory
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {output: "tmp/bench-seed", messages: 2000, users: 100}
  OptionParser.new do |parser|
    parser.on("--output PATH") { |v| options[:output] = v }
    parser.on("--messages N", Integer) { |v| options[:messages] = v }
    parser.on("--users N", Integer) { |v| options[:users] = v }
  end.parse!
  puts Campfire::BenchmarkSeed.create(options[:output], messages: options[:messages], users: options[:users])
end
