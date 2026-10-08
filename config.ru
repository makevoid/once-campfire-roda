# frozen_string_literal: true
require_relative "app"
db = Campfire::Database.connect
Campfire::Database.migrate(db)
Campfire::Database.start_checkpointer(db)
run Campfire::App.build(Campfire::Container.new(db: db))
