# frozen_string_literal: true

require "sequel"
require "sqlite3"
require "fileutils"

module Campfire
  class Database
    def self.connect(path: ENV.fetch("DATABASE_PATH", File.expand_path("../../storage/campfire.sqlite3", __dir__)), pool: ENV.fetch("DB_POOL", "5").to_i)
      FileUtils.mkdir_p(File.dirname(path)) unless path == ":memory:"
      Sequel.default_timezone = :utc
      db = Sequel.sqlite(path, max_connections: path == ":memory:" ? 1 : pool,
        after_connect: proc { |connection|
          # Ruby's busy handler releases the GVL; the native busy_timeout can
          # otherwise prevent the Ruby thread holding a write lock from running.
          connection.busy_handler { |count| sleep(0.002); count < 2500 }
          connection.execute("PRAGMA foreign_keys = ON")
          connection.execute("PRAGMA synchronous = NORMAL")
          connection.execute("PRAGMA cache_size = -16000")
          connection.execute("PRAGMA temp_store = MEMORY")
        })
      db.run("PRAGMA journal_mode = WAL") unless path == ":memory:"
      # All application timestamps are written in UTC with six fractional digits.
      # Sequel's general parser reparses each value and constructs local times;
      # that dominates these small SQLite queries. Keep a fallback for legacy
      # values and explicit offsets instead of silently misreading them.
      general_parser = db.conversion_procs.fetch("datetime")
      utc_parser = proc do |value|
        if value.is_a?(String) && /\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}\z/.match?(value)
          Time.utc(value[0, 4].to_i, value[5, 2].to_i, value[8, 2].to_i,
            value[11, 2].to_i, value[14, 2].to_i, value[17, 2].to_i, value[20, 6].to_i)
        else
          general_parser.call(value)
        end
      end
      db.conversion_procs["datetime"] = db.conversion_procs["timestamp"] = utc_parser
      db.extension(:freeze_datasets)
      db
    end

    def self.migrate(db)
      Sequel.extension :migration
      Sequel::Migrator.run(db, File.expand_path("../../db/migrations", __dir__))
    end

    def self.snapshot(source, destination)
      raise "Destination already exists" if File.exist?(destination)
      source_db = SQLite3::Database.new(source, readonly: true)
      target_db = SQLite3::Database.new(destination)
      backup = SQLite3::Backup.new(target_db, "main", source_db, "main")
      result = backup.step(-1)
      raise "SQLite backup did not finish: #{result}" unless result == SQLite3::Constants::ErrorCode::DONE
    ensure
      backup&.finish
      target_db&.close
      source_db&.close
    end
  end
end
