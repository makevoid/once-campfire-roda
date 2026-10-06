# frozen_string_literal: true
require "active_record"
require "sqlite3"
require "json"
require "fileutils"

schema, source_path, destination = ARGV
abort "Refusing to replace #{destination}" if File.exist?(destination)
FileUtils.mkdir_p(File.dirname(destination))
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: destination)
ActiveRecord::Schema.verbose = false
load schema
ActiveRecord::Base.connection_pool.disconnect!

source = SQLite3::Database.new(source_path, readonly: true, results_as_hash: true)
target = SQLite3::Database.new(destination, results_as_hash: true)
target.execute("PRAGMA foreign_keys = ON")
counts = {}
rails_timestamp = ->(value) { value&.sub(/\.000000\z/, "") }
# Active Record omits the fractional part for whole seconds. Keeping Sequel's
# .000000 suffix would change Rails' strict before/after SQLite comparisons.
target.transaction do
  %w[accounts users rooms memberships messages boosts searches bans].each do |table|
    schema_columns = target.execute("PRAGMA table_info(#{table})")
    date_columns = schema_columns.select { |row| row.fetch("type").start_with?("datetime") }.map { |row| row.fetch("name") }
    columns = schema_columns.map { |row| row.fetch("name") } &
      source.execute("PRAGMA table_info(#{table})").map { |row| row.fetch("name") }
    target.prepare("INSERT INTO #{table} (#{columns.join(',')}) VALUES (#{(['?'] * columns.length).join(',')})") do |statement|
      source.execute("SELECT * FROM #{table} ORDER BY id").each do |row|
        statement.execute(*columns.map { |column| date_columns.include?(column) ? rails_timestamp.call(row.fetch(column)) : row.fetch(column) })
      end
    end
    counts[table] = target.get_first_value("SELECT COUNT(*) FROM #{table}")
  end
  source.execute("SELECT * FROM messages ORDER BY id").each do |message|
    target.execute("INSERT INTO action_text_rich_texts (name, record_type, record_id, body, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
      ["body", "Message", message.fetch("id"), message.fetch("body"), rails_timestamp.call(message.fetch("created_at")), rails_timestamp.call(message.fetch("updated_at"))])
    target.execute("INSERT INTO message_search_index (rowid, body) VALUES (?, ?)", [message.fetch("id"), message.fetch("plain_text")])
  end
end
raise "Foreign key mismatch" unless target.execute("PRAGMA foreign_key_check").empty?
raise "Invalid SQLite fixture" unless target.get_first_value("PRAGMA quick_check") == "ok"
target.execute("ANALYZE")
target.execute("PRAGMA wal_checkpoint(TRUNCATE)")
target.close
source.close
puts JSON.pretty_generate(counts)
