# frozen_string_literal: true
require_relative "test_helper"

class WalCheckpointerTest < Minitest::Test
  def test_stop_tolerates_a_connection_that_closed_just_before_interrupt
    Dir.mktmpdir("campfire-checkpoint-") do |directory|
      checkpoint = Campfire::WalCheckpointer.new(File.join(directory, "missing.sqlite3"), interval: 20)
      checkpoint.start
      wakeup = checkpoint.instance_variable_get(:@wakeup)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      sleep 0.001 until wakeup.num_waiting.positive? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      assert_operator wakeup.num_waiting, :>, 0
      # Exercise the real SQLite error from the interleaving where the owner
      # closes its handle before stop interrupts the captured connection.
      connection = SQLite3::Database.new(":memory:")
      connection.close
      checkpoint.instance_variable_set(:@connection, connection)
      checkpoint.stop
      checkpoint.start
      checkpoint.stop
    ensure
      checkpoint&.instance_variable_set(:@connection, nil)
      checkpoint&.stop
    end
  end

  def test_background_checkpoint_releases_its_lock_and_preserves_committed_data
    Dir.mktmpdir("campfire-checkpoint-") do |directory|
      path = File.join(directory, "data.sqlite3")
      db = Campfire::Database.connect(path: path)
      db.run("PRAGMA wal_autocheckpoint=0")
      db.create_table(:changes) { Integer :n }
      checkpoint = Campfire::WalCheckpointer.new(path, interval: 0.01)
      checkpoint.start
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      sleep 0.005 until File.exist?("#{path}.checkpoint.lock") || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      lock = File.open("#{path}.checkpoint.lock", "a")
      assert_equal false, lock.flock(File::LOCK_EX | File::LOCK_NB)
      30.times { |i| db[:changes].insert(n: i) }
      checkpoint.stop
      assert lock.flock(File::LOCK_EX | File::LOCK_NB)
      lock.close
      assert_equal 30, db[:changes].count
      assert_equal "ok", db.fetch("PRAGMA integrity_check").first.values.first
      checkpoint.start
      checkpoint.stop
    ensure
      checkpoint&.stop
      lock&.close unless lock&.closed?
      db&.disconnect
    end
  end

  def test_contenders_stop_promptly_without_releasing_another_owner_or_creating_a_database
    Dir.mktmpdir("campfire-checkpoint-") do |directory|
      path = File.join(directory, "missing.sqlite3")
      checkpoint = Campfire::WalCheckpointer.new(path, interval: 20)
      checkpoint.start
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      checkpoint.stop
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
      refute File.exist?(path)
      db = Campfire::Database.connect(path: path)
      lock = File.open("#{path}.checkpoint.lock", "a")
      lock.flock(File::LOCK_EX)
      checkpoint.start
      checkpoint.stop
      challenger = File.open("#{path}.checkpoint.lock", "a")
      assert_equal false, challenger.flock(File::LOCK_EX | File::LOCK_NB)
    ensure
      checkpoint&.stop
      lock&.close
      challenger&.close
      db&.disconnect
    end
  end
end
