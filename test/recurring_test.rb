require "test_helper"

module RoundhouseUi
  # Four incompatible schedulers, one view. The valuable part is not listing the
  # crontab — it is deciding whether a task that says hourly has stopped firing.
  class RecurringTaskTest < ActiveSupport::TestCase
    def task(**attrs)
      Recurring::Task.new(**{ name: "t", schedule: "0 * * * *", enabled: true }.merge(attrs))
    end

    # Stub the interval so these assertions hold with or without a cron parser
    # installed — the dummy app has none, and the logic is what is under test.
    def hourly(**attrs)
      t = task(**attrs)
      t.define_singleton_method(:expected_interval) { 3600.0 }
      t
    end

    def test_a_task_that_ran_recently_is_on_schedule
      assert_equal :ok, hourly(last_run: Time.now - 60).status
    end

    # Two intervals of slack on purpose: a job due at :00 that runs at :00:07 is
    # not late, and a view that says it is gets ignored.
    def test_slightly_late_is_not_overdue
      refute hourly(last_run: Time.now - 3_700).overdue?
    end

    def test_missing_several_intervals_is_overdue
      t = hourly(last_run: Time.now - 3 * 86_400)
      assert t.overdue?
      assert_equal :overdue, t.status
    end

    # A paused task is not late; it is off. Reporting it as overdue would make
    # the count meaningless.
    def test_a_disabled_task_is_never_overdue
      t = hourly(last_run: Time.now - 3 * 86_400, enabled: false)
      refute t.overdue?
      assert_equal :paused, t.status
    end

    def test_a_task_that_has_never_run_is_unknown_rather_than_overdue
      t = hourly(last_run: nil)
      refute t.overdue?
      assert_equal :unknown, t.status
    end

    # Without a cron parser the interval is unknowable, and guessing would
    # produce false alarms on every unusual schedule.
    def test_no_interval_means_staleness_is_unknown_not_overdue
      t = task(last_run: Time.now - 10 * 86_400)
      t.define_singleton_method(:expected_interval) { nil }
      refute t.overdue?, "an unknown interval must not be reported as overdue"
    end

    def test_a_malformed_schedule_does_not_raise
      t = task(schedule: "not a cron", last_run: Time.now)
      assert_nothing_raised { t.expected_interval }
      assert_nothing_raised { t.status }
    end
  end

  class RecurringSourcesTest < ActiveSupport::TestCase
    # solid_queue is a development dependency here, so SolidQueue::RecurringTask
    # is defined and detection correctly reports a source. That is the feature
    # working, not a bug — this asserts it rather than pretending otherwise.
    def test_a_loaded_scheduler_is_detected
      assert Recurring.detected?(:solid_queue), "solid_queue is loaded in this suite"
      assert Recurring.any?
    end

    def test_absent_schedulers_are_not_claimed
      refute Recurring.detected?(:sidekiq_cron)
      refute Recurring.detected?(:sidekiq_ent)
    end

    # The tables do not exist in the dummy app, so reading them raises — and the
    # page must survive that rather than 500.
    def test_a_detected_but_unusable_source_yields_no_tasks
      assert_empty Recurring.tasks
    end

    # A half-configured scheduler must not take the page down, and must not hide
    # the schedulers that are working.
    def test_a_raising_source_is_skipped_rather_than_fatal
      result = Recurring.safely(:broken) { raise "scheduler exploded" }
      assert_equal [], result
    end

    def test_a_source_returning_one_task_is_wrapped
      assert_equal 1, Recurring.safely(:x) { Recurring::Task.new(name: "a") }.size
    end
  end

  class RecurringPageTest < ActionDispatch::IntegrationTest
    def test_the_page_explains_itself_when_no_scheduler_is_installed
      get "/roundhouse/recurring"
      assert_response :success
      assert_match "No recurring jobs found", @response.body
      assert_match "sidekiq-cron", @response.body
    end

    # The nav item appears when a scheduler is detected, and solid_queue is in
    # this suite. The hidden case is covered by stubbing detection, since the
    # dependency cannot be unloaded.
    def test_the_nav_item_appears_when_a_scheduler_is_detected
      get "/roundhouse/queues"
      assert_select "#rh-rail a[href=?]", "/roundhouse/recurring", count: 1
    end

    def test_the_nav_item_is_hidden_when_nothing_is_detected
      stub_method(Recurring, :any?, false) do
        get "/roundhouse/queues"
        assert_select "#rh-rail a[href=?]", "/roundhouse/recurring", count: 0
      end
    end
  end
end
