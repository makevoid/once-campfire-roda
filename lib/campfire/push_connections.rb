# frozen_string_literal: true
# Adapted from Campfire WebPush::Connections, MIT, copyright 37signals, LLC.
# Pool identity includes the freshly vetted address, preserving DNS rebinding
# protection and hostname certificate verification on every delivery.
class Campfire::PushConnections
  class ConnectionLost < StandardError; end
  class StaleConnection < StandardError; end

  # Where a request failed. Before writing it, Net::HTTP checks an idle connection (:checking) and connects again
  # if the push service closed it (:connecting); then it writes (:sent). Only a failed check means a dead idle
  # connection that a new one can replace without sending the push twice.
  module Stages
    attr_reader :stage

    private
      def begin_transport(...)
        @stage = :checking
        super.tap { @stage = :sent }
      end

      def connect(...)
        @stage = :connecting if @stage == :checking
        super
      end
  end

  def initialize(keep_alive_timeout: 30, max_idle: 150)
    @keep_alive_timeout = keep_alive_timeout
    @max_idle = max_idle
    @idle = Hash.new { |idle, address| idle[address] = [] }
    @mutex = Mutex.new
    @pid = Process.pid
  end

  def request(http, request, &block)
    unless http.ipaddr && !http.proxy? && http.use_ssl? && !http.started?
      raise ArgumentError, "Only new, direct TLS connections pinned to an address are pooled"
    end
    address = [ http.address, http.port, http.ipaddr ]

    if idle = checkout(address)
      begin
        return send_over(idle, request, reused: true, &block).tap { checkin(address, idle) }
      rescue StaleConnection
        # The push service had closed it: a new connection takes the push
      end
    end

    http.extend Stages
    http.keep_alive_timeout = @keep_alive_timeout
    http.max_retries = 0
    http.start
    send_over(http, request, reused: false, &block).tap { checkin(address, http) }
  end

  def shutdown
    @mutex.synchronize do
      forget_after_fork
      @shut_down = true
      @idle.each_value { |connections| connections.each { |http, _| close(http) } }
      @idle.clear
    end
  end

  private
    def send_over(http, request, reused:, &block)
      completed = false
      response = http.request(request, &block)
      completed = true
      response
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError => error
      close(http)
      # Only a connection that was idle can have been dead already: on a new one the error is the push service's
      raise StaleConnection if reused && http.stage == :checking
      # The push service may have it: don't send it twice, and don't report a dropped connection as a TLS failure
      raise ConnectionLost, "#{error.class}: #{error.message}" if http.stage == :sent
      raise
    ensure
      close(http) unless completed
    end

    def checkout(address)
      @mutex.synchronize do
        forget_after_fork
        close_expired
        @idle[address].pop&.first
      end
    end

    def checkin(address, http)
      @mutex.synchronize do
        close_expired
        if @shut_down || @idle.values.sum(&:size) >= @max_idle
          close(http)
        else
          @idle[address].push [ http, now ]
        end
      end
    end

    # A forked process must not write on its parent's TLS sessions. They're left to the parent, not closed.
    def forget_after_fork
      unless @pid == Process.pid
        @idle = Hash.new { |idle, address| idle[address] = [] }
        @pid = Process.pid
      end
    end

    def close_expired
      @idle.each_value do |connections|
        connections.reject! { |http, idle_since| (now - idle_since > @keep_alive_timeout).tap { |expired| close(http) if expired } }
      end
      @idle.delete_if { |_, connections| connections.empty? }
    end

    def close(http)
      http.finish if http.started?
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end
