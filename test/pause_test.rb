require "test_helper"

module RoundhouseUi
  class PauseTest < ActiveSupport::TestCase
    def test_pause_unpause_roundtrip
      with_fake_redis do
        refute Pause.paused?("low")
        Pause.pause!("low")
        assert Pause.paused?("low")
        assert_equal [ "low" ], Pause.paused_queues
        Pause.unpause!("low")
        refute Pause.paused?("low")
        assert_empty Pause.paused_queues
      end
    end

    def test_reject_paused_drops_only_paused_queue_keys
      with_fake_redis do
        Pause.pause!("low")
        keys = %w[queue:default queue:low queue:mailers]
        assert_equal %w[queue:default queue:mailers], Pause.reject_paused(keys)
      end
    end

    def test_reject_paused_is_a_noop_when_nothing_paused
      with_fake_redis do
        keys = %w[queue:default queue:low]
        assert_equal keys, Pause.reject_paused(keys)
      end
    end

    def test_fetch_liveness_beacon
      with_fake_redis do
        refute Pause.fetch_installed?, "no beacon yet"
        Pause.mark_fetch_alive!
        assert Pause.fetch_installed?, "beacon present after the fetcher reports in"
      end
    end

    # --- Sidekiq Pro's native pause -----------------------------------------
    # Pro reopens Sidekiq::Queue with pause!/unpause! and prepends pause support
    # onto Sidekiq::BasicFetch. We can't load Pro here (commercial gem), so stand
    # in for its API surface and assert we delegate to it.

    # Records that #pause! was called, and mutates Pro's key like Pro does, so
    # the read path can be checked against the same set.
    class FakeProQueue
      class << self
        attr_accessor :calls
      end
      self.calls = []

      def initialize(name) = @name = name

      def pause!
        self.class.calls << [ :pause!, @name ]
        Sidekiq.redis { |conn| conn.call("SADD", Pause::PRO_KEY, @name) }
        true
      end

      def unpause!
        self.class.calls << [ :unpause!, @name ]
        Sidekiq.redis { |conn| conn.call("SREM", Pause::PRO_KEY, @name) }
        true
      end
    end

    def with_sidekiq_pro
      FakeProQueue.calls = []
      original = Sidekiq.send(:remove_const, :Queue)
      Sidekiq.const_set(:Queue, FakeProQueue)
      yield
    ensure
      Sidekiq.send(:remove_const, :Queue)
      Sidekiq.const_set(:Queue, original)
    end

    def test_native_is_false_on_oss_sidekiq
      refute Pause.native?, "OSS Sidekiq::Queue has no pause!"
    end

    def test_native_is_detected_when_pro_defines_pause
      with_sidekiq_pro { assert Pause.native? }
    end

    def test_pause_delegates_to_pro_rather_than_writing_our_own_key
      with_fake_redis do |fake|
        with_sidekiq_pro do
          Pause.pause!("low")
          assert_equal [ [ :pause!, "low" ] ], FakeProQueue.calls,
            "must go through Sidekiq::Queue#pause! so Pro publishes its pubsub message"
          assert_equal 0, fake.call("SISMEMBER", Pause::KEY, "low"),
            "our own registry must be left untouched under Pro"
        end
      end
    end

    def test_reads_come_from_pros_registry_under_pro
      with_fake_redis do
        with_sidekiq_pro do
          Pause.pause!("low")
          assert Pause.paused?("low")
          assert_equal [ "low" ], Pause.paused_queues
          assert_equal Set.new([ "low" ]), Pause.paused_set

          Pause.unpause!("low")
          refute Pause.paused?("low")
          assert_empty Pause.paused_queues
        end
      end
    end

    def test_our_own_paused_queues_are_ignored_under_pro
      with_fake_redis do |fake|
        fake.call("SADD", Pause::KEY, "legacy") # stale Roundhouse-era entry
        with_sidekiq_pro do
          assert_empty Pause.paused_queues, "Pro's registry is the only source of truth"
        end
      end
    end

    def test_pro_needs_no_fetcher_beacon
      with_fake_redis do
        with_sidekiq_pro do
          assert Pause.fetch_installed?, "Pro enforces pause without our fetcher"
        end
      end
    end

    def test_backend_advertises_native_pause_only_under_pro
      backend = Backends::Sidekiq.new
      refute backend.supports?(:native_pause), "OSS Sidekiq needs the fetcher"
      with_sidekiq_pro { assert backend.supports?(:native_pause) }
    end
  end
end
