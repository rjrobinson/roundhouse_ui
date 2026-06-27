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
  end
end
