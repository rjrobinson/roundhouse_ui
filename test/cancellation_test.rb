require "test_helper"

module RoundhouseUi
  class CancellationTest < ActiveSupport::TestCase
    # Wraps a fake connection and counts commands, so tests can assert what the
    # hot path actually costs in Redis round-trips.
    class CountingRedis
      attr_reader :counts

      def initialize(inner)
        @inner = inner
        @counts = Hash.new(0)
      end

      def call(cmd, *args)
        @counts[cmd.to_s.upcase] += 1
        @inner.call(cmd, *args)
      end
    end

    # The gate caches process-wide state; forget it so tests are order-proof.
    def setup = Cancellation.reset_gate!
    def teardown = Cancellation.reset_gate!

    def with_counting_redis
      counting = CountingRedis.new(FakeRedis.new)
      original = Sidekiq.method(:redis)
      Sidekiq.define_singleton_method(:redis) { |&blk| blk.call(counting) }
      yield counting
    ensure
      Sidekiq.define_singleton_method(:redis, original)
    end

    def test_cancel_check_clear_roundtrip
      with_fake_redis do
        refute Cancellation.cancelled?("j1")
        Cancellation.cancel!("j1")
        assert Cancellation.cancelled?("j1")
        assert RoundhouseUi.cancelled?("j1") # convenience delegate
        Cancellation.clear!("j1")
        refute Cancellation.cancelled?("j1")
      end
    end

    def test_middleware_skips_a_cancelled_job
      with_fake_redis do
        Cancellation.cancel!("j1")
        ran = false
        CancelMiddleware.new.call(nil, { "jid" => "j1" }, "default") { ran = true }
        refute ran, "cancelled job is skipped"
        refute Cancellation.cancelled?("j1"), "flag is cleared after skipping"
      end
    end

    def test_middleware_runs_a_normal_job
      with_fake_redis do
        ran = false
        CancelMiddleware.new.call(nil, { "jid" => "j2" }, "default") { ran = true }
        assert ran
      end
    end

    def test_idle_hot_path_costs_one_gate_check_per_window_not_per_job
      with_counting_redis do |counting|
        ran = 0
        # Fresh instance per call, mirroring Sidekiq's Chain#invoke.
        5.times { |i| CancelMiddleware.new.call(nil, { "jid" => "j#{i}" }, "default") { ran += 1 } }
        assert_equal 5, ran
        assert_equal 1, counting.counts["EXISTS"], "one gate check per window"
        assert_equal 0, counting.counts["SISMEMBER"], "no per-job membership checks while idle"
      end
    end

    def test_the_cancelling_process_sees_its_own_cancel_immediately
      with_fake_redis do
        # Prime the gate into its cached-empty state first.
        CancelMiddleware.new.call(nil, { "jid" => "j1" }, "default") { }
        Cancellation.cancel!("j1")
        ran = false
        CancelMiddleware.new.call(nil, { "jid" => "j1" }, "default") { ran = true }
        refute ran, "cancel! busts the local gate — no staleness in-process"
      end
    end

    def test_a_cancel_from_another_process_lands_within_the_window
      with_fake_redis do |fake|
        CancelMiddleware.new.call(nil, { "jid" => "j9" }, "default") { } # gate now cached empty
        fake.call("SADD", Cancellation::KEY, "j9") # another process cancels: no local gate bust

        ran = false
        CancelMiddleware.new.call(nil, { "jid" => "j9" }, "default") { ran = true }
        assert ran, "within the window the stale gate lets the job through (documented tradeoff)"

        Cancellation.reset_gate! # the window elapses
        ran = false
        CancelMiddleware.new.call(nil, { "jid" => "j9" }, "default") { ran = true }
        refute ran, "after the window the cancel is honored"
      end
    end

    def test_the_gate_closes_again_once_the_set_drains
      with_fake_redis do
        Cancellation.cancel!("j1")
        assert Cancellation.pending?
        Cancellation.clear!("j1") # last member removed — Redis deletes the key
        Cancellation.reset_gate!
        refute Cancellation.pending?
      end
    end
  end
end
