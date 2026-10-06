# frozen_string_literal: true
threads_count = Integer(ENV.fetch("MAX_THREADS", "5"))
threads threads_count, threads_count
workers Integer(ENV.fetch("WEB_CONCURRENCY", "0"))
bind "tcp://#{ENV.fetch('HOST', '127.0.0.1')}:#{ENV.fetch('PORT', '9292')}"
environment ENV.fetch("RACK_ENV", "development")
worker_timeout 60
