# frozen_string_literal: true
require "etc"

app_environment = ENV.fetch("RACK_ENV", "development")
# Rails enables YJIT for production automatically; give the native server the
# same runtime optimization, with the standard environment opt-out preserved.
RubyVM::YJIT.enable if app_environment == "production" && defined?(RubyVM::YJIT) && ENV["RUBY_YJIT_ENABLE"] != "0"
threads_count = Integer(ENV.fetch("MAX_THREADS", "2"))
worker_setting = ENV.fetch("WEB_CONCURRENCY", app_environment == "production" ? "auto" : "0")
# Leave capacity for the OS, reverse proxy and delivery worker. No extra gem is
# needed for CPU detection; use an explicit count for container CPU/RAM limits.
worker_count = worker_setting == "auto" ? [Etc.nprocessors - 2, 1].max : Integer(worker_setting)
worker_count = 0 if worker_setting == "auto" && worker_count == 1
raise ArgumentError, "MAX_THREADS must be positive" unless threads_count.positive?
raise ArgumentError, "WEB_CONCURRENCY must be nonnegative" if worker_count.negative?

threads threads_count, threads_count
workers worker_count
if worker_count.positive?
  preload_app!
  # Boot/migrate once in the master, then give every child its own connections.
  before_fork do
    Campfire::Database.stop_checkpointers
    Sequel::DATABASES.each(&:disconnect)
  end
  before_worker_boot { Campfire::Database.start_checkpointers }
end
bind "tcp://#{ENV.fetch('HOST', '127.0.0.1')}:#{ENV.fetch('PORT', '9292')}"
environment app_environment
worker_timeout 60
