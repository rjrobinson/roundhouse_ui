require_relative "../real_redis_test_case"

module RoundhouseUi
  # "Bulk retry or delete scoped to a filter — every job matching your search, not
  # just the page you can see." The feature the whole project was written for, and
  # it runs against Redis sorted sets, which the fake models as a plain list with
  # the scores thrown away.
  class RealRedisBulkOnFilterTest < RealRedisTestCase
    # Exercises the scan predicate directly, with no request cycle around it — so
    # it has to absorb the concern's before_action registration. Defining this
    # rather than guarding the concern: the concern is for controllers, and the
    # bare object is the unusual thing here.
    class Browser
      def self.before_action(*) = nil
      include JobSetBrowsing
    end

    # A real retry entry: JSON in the `retry` zset, scored by when it is due.
    def seed_retry(klass:, jid:, args: [], queue: "default", error: "Timeout::Error", at: Time.now.to_f)
      payload = Sidekiq.dump_json(
        "class" => klass, "args" => args, "queue" => queue, "jid" => jid,
        "retry_count" => 1, "error_class" => error, "error_message" => "boom",
        "failed_at" => at
      )
      Sidekiq.redis { |conn| conn.call("ZADD", "retry", at.to_s, payload) }
    end

    def browser = @browser ||= Browser.new

    def test_a_bulk_delete_takes_every_match_and_nothing_else
      30.times { |i| seed_retry(klass: "BillingWorker", jid: "bill#{i}", at: Time.now.to_f + i) }
      20.times { |i| seed_retry(klass: "MailerWorker", jid: "mail#{i}", at: Time.now.to_f + i) }
      assert_equal 50, Sidekiq::RetrySet.new.size

      found = browser.bulk_apply(Sidekiq::RetrySet.new, "BillingWorker", "delete")

      assert_equal 30, found.entries.size
      refute found.capped
      remaining = Sidekiq::RetrySet.new.map(&:klass)
      assert_equal 20, remaining.size, "a bulk delete over a real sorted set left matches behind"
      assert_equal [ "MailerWorker" ], remaining.uniq, "it deleted something it should not have"
    end

    def test_deleting_more_than_one_page_worth_does_not_skip_entries
      # bulk_matches collects before acting, because removing from a set while
      # iterating it makes the iterator skip. That reasoning has only ever been
      # checked against a fake whose "sorted set" is an array.
      120.times { |i| seed_retry(klass: "BillingWorker", jid: "b#{i}", at: Time.now.to_f + i) }

      browser.bulk_apply(Sidekiq::RetrySet.new, "BillingWorker", "delete")

      assert_equal 0, Sidekiq::RetrySet.new.size,
        "#{Sidekiq::RetrySet.new.size} of 120 survived a delete-all-matching"
    end

    def test_the_cap_stops_at_the_cap_and_says_so
      30.times { |i| seed_retry(klass: "BillingWorker", jid: "b#{i}", at: Time.now.to_f + i) }

      found = browser.bulk_apply(Sidekiq::RetrySet.new, "BillingWorker", "delete", 10)

      assert found.capped, "the cap was hit but not reported"
      assert_equal 10, found.entries.size
      assert_equal 20, Sidekiq::RetrySet.new.size
    end

    def test_searching_an_argument_value_finds_the_job
      seed_retry(klass: "BillingWorker", jid: "needle", args: [ { "account_id" => 90210 } ])
      10.times { |i| seed_retry(klass: "BillingWorker", jid: "hay#{i}", args: [ { "account_id" => i } ]) }

      jobs, = browser.browse(Sidekiq::RetrySet.new, "90210", 1)

      assert_equal [ "needle" ], jobs.map(&:jid),
        "argument search is the reason this project exists"
    end

    def test_paging_a_real_sorted_set_neither_repeats_nor_skips
      60.times { |i| seed_retry(klass: "BillingWorker", jid: "b#{i}", at: Time.now.to_f + i) }

      page1, has_next1 = browser.browse(Sidekiq::RetrySet.new, "", 1)
      page2, has_next2 = browser.browse(Sidekiq::RetrySet.new, "", 2)
      page3, = browser.browse(Sidekiq::RetrySet.new, "", 3)

      assert has_next1
      assert has_next2
      seen = (page1 + page2 + page3).map(&:jid)
      assert_equal 60, seen.size
      assert_equal 60, seen.uniq.size, "paging returned the same job on two pages"
    end
    def test_find_more_like_this_narrows_a_bulk_delete_to_exactly_that_issue
      # The glass exists to reveal these controls, so what it selects is what gets
      # deleted. A substring class filter would take BillingWorkerLegacy with it.
      2.times { |i| seed_retry(klass: "BillingWorker",       jid: "hit#{i}",  error: "Timeout::Error") }
      seed_retry(klass: "BillingWorker",       jid: "other",  error: "ArgumentError")
      seed_retry(klass: "BillingWorkerLegacy", jid: "legacy", error: "Timeout::Error")
      seed_retry(klass: "MailerWorker",        jid: "mailer", error: "Timeout::Error")

      b = browser
      b.instance_variable_set(:@class_filter, "BillingWorker")
      b.instance_variable_set(:@error_filter, "Timeout::Error")
      found = b.bulk_apply(Sidekiq::RetrySet.new, "", "delete")

      assert_equal 2, found.entries.size
      remaining = Sidekiq::RetrySet.new.map(&:jid).sort
      assert_equal %w[legacy mailer other], remaining,
        "a bulk delete on the like-this filter took rows it was not shown"
    end

    def test_the_class_filter_alone_still_spares_a_longer_name
      seed_retry(klass: "BillingWorker",       jid: "hit",    error: "Boom")
      seed_retry(klass: "BillingWorkerLegacy", jid: "legacy", error: "Boom")

      b = browser
      b.instance_variable_set(:@class_filter, "BillingWorker")
      b.bulk_apply(Sidekiq::RetrySet.new, "", "delete")

      assert_equal %w[legacy], Sidekiq::RetrySet.new.map(&:jid)
    end
  end
end
