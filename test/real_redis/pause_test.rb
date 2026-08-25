require_relative "../real_redis_test_case"

module RoundhouseUi
  # "Enforced pause — a paused queue actually stops being worked, on OSS Sidekiq
  # too" is the README's claim. The mechanism is a Redis set plus a fetcher that
  # subtracts it from the queue list, and neither had ever met a real Redis.
  class RealRedisPauseTest < RealRedisTestCase
    def test_a_paused_queue_is_removed_from_what_the_fetcher_polls
      Pause.pause!("billing")

      # The exact call Fetch#queues_cmd makes, on the shape Sidekiq hands it.
      remaining = Pause.reject_paused(%w[queue:billing queue:mailers])

      assert_equal %w[queue:mailers], remaining
      assert Pause.paused?("billing")
      refute Pause.paused?("mailers")
    end

    def test_unpausing_the_last_queue_leaves_no_key_behind
      # Real Redis deletes a set when its final member is removed; the fake had to
      # special-case that to stop an empty materialised array reading as present.
      # If the key lingered, `paused_set` would be empty but EXISTS would say yes.
      Pause.pause!("billing")
      Pause.unpause!("billing")

      exists = Sidekiq.redis { |conn| conn.call("EXISTS", Pause::KEY) }

      assert_equal 0, exists, "the paused-queue key outlived its last member"
      assert_empty Pause.paused_set
    end

    def test_the_liveness_beacon_is_written_with_a_real_expiry
      # The fake answers EXPIRE with 1 and EXISTS with 1 unconditionally, so the
      # beacon's whole reason for existing — that it disappears once the fetchers
      # stop — has never been observed. Without a TTL the UI would claim pause was
      # enforced forever after one boot with the fetcher installed.
      Pause.mark_fetch_alive!(30)

      assert Pause.fetch_installed?
      ttl = Sidekiq.redis { |conn| conn.call("TTL", Pause::FETCH_FLAG) }
      assert_operator ttl, :>, 0, "the beacon has no expiry; pause would read as enforced forever"
      assert_operator ttl, :<=, 30
    end

    def test_the_beacon_is_absent_before_any_fetcher_reports
      refute Pause.fetch_installed?,
        "a fresh Redis reports the fetcher as installed, so the warning would never show"
    end
  end
end
