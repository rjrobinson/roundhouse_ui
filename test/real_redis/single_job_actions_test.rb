require_relative "../real_redis_test_case"

module RoundhouseUi
  # Every per-row action starts with `find_job(jid)`, and none of them had ever
  # been executed: Sidekiq::SortedSet#find_job issues ZSCAN, which FakeRedis
  # cannot answer at all — it raises "unexpected command ZSCAN". So the first
  # line of retries#destroy, retries#requeue, dead#destroy, dead#requeue, every
  # scheduled action and jobs#show/edit/update was untested.
  #
  # Found while chasing a report that the Retries delete button did not work. It
  # does; the set it was deleting from was being refilled faster than a row could
  # be removed. These pin it so the question does not have to be asked again.
  class RealRedisSingleJobActionsTest < RealRedisTestCase
    include ::Rails.application.routes.url_helpers

    def seed_retry(jid, klass: "BillingWorker")
      payload = Sidekiq.dump_json(
        "class" => klass, "args" => [], "queue" => "default", "jid" => jid,
        "retry_count" => 1, "error_class" => "Timeout::Error", "failed_at" => Time.now.to_f
      )
      Sidekiq.redis { |conn| conn.call("ZADD", "retry", "0", payload) }
    end

    def test_find_job_locates_a_real_entry_by_jid
      seed_retry("needle")
      3.times { |i| seed_retry("hay#{i}") }

      found = RoundhouseUi.backend.retry_set.find_job("needle")

      refute_nil found, "find_job could not locate a job that is in the set"
      assert_equal "needle", found.jid
    end

    def test_deleting_one_entry_removes_exactly_that_one
      seed_retry("doomed")
      3.times { |i| seed_retry("keep#{i}") }

      RoundhouseUi.backend.retry_set.find_job("doomed").delete

      remaining = Sidekiq::RetrySet.new.map(&:jid)
      assert_equal 3, remaining.size
      refute_includes remaining, "doomed"
    end

    def test_find_job_returns_nil_for_a_jid_that_has_gone
      seed_retry("present")

      assert_nil RoundhouseUi.backend.retry_set.find_job("vanished"),
        "a missing jid must read as nil so the controller can say so"
    end
  end

  # The same path through the full stack, because "it worked but said nothing"
  # and "it did not work" look identical from a browser.
  class RealRedisDeleteFeedbackTest < ActionDispatch::IntegrationTest
    self.fake_redis = false

    def setup
      skip "set ROUNDHOUSE_TEST_REDIS_URL" unless RealRedisTestCase::URL
      Sidekiq.configure_client { |c| c.redis = { url: RealRedisTestCase::URL } }
      Sidekiq.redis { |conn| conn.call("FLUSHDB") }
      RoundhouseUi.read_only = false
    end

    def teardown
      Sidekiq.redis { |conn| conn.call("FLUSHDB") } if RealRedisTestCase::URL
    end

    def markup = response.body.split("</style>").last.to_s

    def test_a_delete_removes_the_job_and_says_which_one
      payload = Sidekiq.dump_json("class" => "W", "args" => [], "queue" => "default",
                                  "jid" => "abc123", "retry_count" => 1)
      Sidekiq.redis { |conn| conn.call("ZADD", "retry", "0", payload) }

      post "/roundhouse/retries/abc123/delete"
      assert_response :see_other
      follow_redirect!

      assert_equal 0, Sidekiq::RetrySet.new.size, "the job survived the delete"
      assert_match "rh-flash", markup, "the page gave no feedback at all"
      assert_match "Deleted abc123", markup, "it deleted the job without saying so"
    end

    def test_deleting_something_already_gone_says_that_instead
      post "/roundhouse/retries/vanished/delete"
      follow_redirect!

      assert_match "no longer in the retry set", markup,
        "a no-op and a success must not look the same"
    end
  end
end
