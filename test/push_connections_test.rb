# frozen_string_literal: true
# Adapted from Campfire, MIT, copyright 37signals, LLC.
require_relative "test_helper"
require_relative "push_service_helper"

class PushConnectionsTest < Minitest::Test
  include PushServiceTestHelper

  def setup = @connections = Campfire::PushConnections.new
  def teardown = @connections.shutdown

  def test_a_delivery_to_the_same_host_and_address_reuses_the_open_connection
    with_push_service do |server|
      2.times { |i| assert_kind_of Net::HTTPCreated, @connections.request(pinned_connection(server), push_request("/push/#{i}")) }

      assert_equal 1, server.connections
      assert_equal %w[ /push/0 /push/1 ], server.requests
    end
  end

  def test_failed_response_consumption_closes_the_connection_before_reuse
    with_push_service do |server|
      assert_raises(Campfire::Error) do
        @connections.request(pinned_connection(server), push_request) { raise Campfire::Error, "Response limit" }
      end
      assert server.hung_up?
      @connections.request(pinned_connection(server), push_request)
      assert_equal 2, server.connections
    end
  end

  def test_outbound_transport_rechecks_addresses_before_using_a_pooled_connection
    with_push_service do |server|
      transport = Campfire::OutboundHTTP.new(connections: @connections)
      old_proxy = ENV["https_proxy"]
      ENV["https_proxy"] = "http://invalid.test:1234"
      Resolv.stub(:getaddresses, [IP]) do
        # The network is local only in this test. Production keeps the real guard.
        Campfire::OutboundHTTP.stub(:public_address?, true) do
          2.times { assert_equal "201", transport.post("https://#{HOST}:#{server.port}/push", headers: {}, body: "test").code }
        end
        assert_raises(Campfire::Error) { transport.post("https://#{HOST}:#{server.port}/push", headers: {}, body: "test") }
      end
      assert_equal 1, server.connections
      assert_equal 2, server.requests.size
    ensure
      ENV["https_proxy"] = old_proxy
    end
  end

  def test_a_delivery_to_another_address_never_reuses_a_connection
    with_push_service do |server|
      @connections.request(pinned_connection(server), push_request)

      other = pinned_connection(server, "127.0.0.2")
      other.define_singleton_method(:start) {}
      other.define_singleton_method(:request) { |*| :sent_to_the_other_address }
      assert_equal :sent_to_the_other_address, @connections.request(other, push_request)
      assert_equal 1, server.requests.size
    end
  end

  def test_a_connection_the_push_service_closed_while_idle_is_replaced_and_the_push_sent_once
    [ :fin, :close_notify ].each do |hang_up|
      with_push_service(hang_up_after_response: hang_up) do |server|
        @connections.request(pinned_connection(server), push_request("/push/0"))
        assert server.hung_up?

        assert_kind_of Net::HTTPCreated, @connections.request(pinned_connection(server), push_request("/push/1"))
        assert_equal 2, server.connections
        assert_equal %w[ /push/0 /push/1 ], server.requests
      end
    end
  end

  def test_a_certificate_for_another_name_is_refused_and_nothing_is_sent
    with_push_service(certificate: ->(_) { "other.test" }) do |server|
      assert_raises(OpenSSL::SSL::SSLError) { @connections.request(pinned_connection(server), push_request) }
      assert_empty server.requests
    end
  end

  def test_a_certificate_for_another_name_is_refused_when_a_dead_connection_is_replaced_too
    with_push_service(hang_up_after_response: :fin, certificate: ->(connection) { connection == 1 ? HOST : "other.test" }) do |server|
      @connections.request(pinned_connection(server), push_request)
      assert server.hung_up?

      assert_raises(OpenSSL::SSL::SSLError) { @connections.request(pinned_connection(server), push_request) }
      assert_equal 1, server.requests.size
    end
  end

  def test_a_push_the_service_may_have_received_is_not_sent_again
    with_push_service(drop_request: ->(number) { number == 2 }) do |server|
      @connections.request(pinned_connection(server), push_request("/push/0"))

      error = assert_raises(Campfire::PushConnections::ConnectionLost) { @connections.request(pinned_connection(server), push_request("/push/1")) }
      refute_kind_of OpenSSL::OpenSSLError, error
      assert_equal %w[ /push/0 /push/1 ], server.requests
      assert_equal 1, server.connections
    end
  end

  def test_a_push_the_service_may_have_received_on_a_new_connection_isn_t_reported_as_a_tls_failure_either
    with_push_service(drop_request: ->(number) { number == 1 }) do |server|
      error = assert_raises(Campfire::PushConnections::ConnectionLost) { @connections.request(pinned_connection(server), push_request) }
      refute_kind_of OpenSSL::OpenSSLError, error
      assert_equal 1, server.requests.size
    end
  end

  def test_a_tls_failure_on_a_new_connection_before_the_push_is_written_is_reported_as_it_is
    failing_check = Module.new { private def begin_transport(*) = raise(OpenSSL::SSL::SSLError, "alert right after the handshake") }

    with_push_service do |server|
      assert_raises(OpenSSL::SSL::SSLError) { @connections.request(pinned_connection(server).extend(failing_check), push_request) }
      assert_empty server.requests
    end
  end

  def test_a_certificate_for_another_name_when_reconnecting_a_cleanly_closed_connection_is_reported_even_if_a_new_one_would_work
    certificates = { 2 => "other.test" }
    with_push_service(hang_up_after_response: :close_notify, certificate: ->(connection) { certificates.fetch(connection, HOST) }) do |server|
      @connections.request(pinned_connection(server), push_request)
      assert server.hung_up?

      assert_raises(OpenSSL::SSL::SSLError) { @connections.request(pinned_connection(server), push_request) }
      assert_equal 1, server.requests.size
      assert_equal 2, server.connections
    end
  end

  def test_only_new_direct_tls_connections_pinned_to_an_address_are_pooled
    with_push_service do |server|
      unpinned = Net::HTTP.new(HOST, server.port, nil).tap { it.use_ssl = true }
      proxied = Net::HTTP.new(HOST, server.port, "127.0.0.1", 3128).tap { it.ipaddr = IP; it.use_ssl = true }
      plain = pinned_connection(server).tap { it.use_ssl = false }
      started = pinned_connection(server).tap(&:start)

      [ unpinned, proxied, plain, started ].each do |http|
        assert_raises(ArgumentError) { @connections.request(http, push_request) }
      end
      assert_empty server.requests
    ensure
      started&.finish
    end
  end

  def test_a_forked_process_opens_its_own_connections
    with_push_service do |server|
      @connections.request(pinned_connection(server), push_request)

      child = Process.pid + 1
      Process.stub(:pid, child) { @connections.request(pinned_connection(server), push_request) }
      assert_equal 2, server.connections
    end
  end

  def test_a_forked_process_shutting_down_leaves_its_parent_s_connections_open
    with_push_service do |server|
      @connections.request(pinned_connection(server), push_request)

      child = Process.pid + 1
      Process.stub(:pid, child) { @connections.shutdown }
      refute server.hung_up?(within: 0.5)
    end
  end

  def test_the_idle_pool_closes_connections_beyond_its_bound
    connections = Campfire::PushConnections.new(max_idle: 1)

    with_push_service do |server|
      other = Server.new
      connections.request(pinned_connection(server), push_request)
      connections.request(pinned_connection(other), push_request)
      assert other.hung_up?
      refute server.hung_up?(within: 0.1)

      connections.request(pinned_connection(server), push_request)
      assert_equal 1, server.connections
    ensure
      connections.shutdown
      other&.stop
    end
  end

  def test_idle_connections_are_closed_after_the_keep_alive_timeout_and_on_shutdown
    connections = Campfire::PushConnections.new(keep_alive_timeout: 0)

    with_push_service do |server|
      other = Server.new
      connections.request(pinned_connection(server), push_request)
      connections.request(pinned_connection(other), push_request)
      assert server.hung_up?

      connections.shutdown
      assert other.hung_up?

      connections.request(pinned_connection(server), push_request)
      assert server.hung_up?
    ensure
      other&.stop
    end
  end
end
