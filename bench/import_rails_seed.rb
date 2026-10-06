#!/usr/bin/env ruby
# frozen_string_literal: true
require "bundler/setup"
require "optparse"
require_relative "../lib/campfire/importer"

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: bundle exec ruby bench/import_rails_seed.rb --database RAILS.sqlite3 --labels labels.json --output NEW_DIRECTORY [--storage PATH]"
  parser.on("--database PATH") { |v| options[:database] = v }
  parser.on("--labels PATH") { |v| options[:labels] = v }
  parser.on("--output PATH") { |v| options[:output] = v }
  parser.on("--storage PATH") { |v| options[:storage] = v }
end.parse!
abort "--database, --labels, and --output are required" unless %i[database labels output].all? { |key| options[key] }
abort "Source database does not exist" unless File.file?(options[:database])
path = File.join(options[:output], "campfire.sqlite3")
abort "Refusing to replace an existing output database" if File.exist?(path)
labels = JSON.parse(File.read(options[:labels]))
%w[emails.david passwords.all rooms.watercooler messages.busy_060].each { |key| labels.fetch(key) }
db = Campfire::Database.connect(path: path)
Campfire::Database.migrate(db)
container = Campfire::Container.new(db: db, upload_root: File.join(options[:output], "files"))
counts = Campfire::Importer.new(source: options[:database], target: container, rails_storage: options[:storage]).run
labels.merge!("fixture" => "campfire-roda-benchmark-v1", "messages.count" => counts.fetch(:messages), "users.count" => counts.fetch(:users))
File.write(File.join(options[:output], "labels.json"), JSON.pretty_generate(labels) + "\n")
db.run("PRAGMA wal_checkpoint(TRUNCATE)")
db.disconnect
puts "Imported matching Rails fixture into #{options[:output]}"
