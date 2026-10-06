# frozen_string_literal: true
require "rake/testtask"
Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end
task default: :test
namespace :db do
  desc "Create or migrate the Roda database"
  task :migrate do
    require_relative "lib/campfire/database"
    db = Campfire::Database.connect
    Campfire::Database.migrate(db)
    puts "Database migrated"
  end
end
desc "Run Puma on localhost:9292"
task :dev do
  exec "bundle", "exec", "puma", "-C", "config/puma.rb"
end
