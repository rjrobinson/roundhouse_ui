require "test_helper"

module RoundhouseUi
  # Daily counts Sidekiq already keeps (#61). The value is the comparison — is
  # today normal — so the arithmetic that produces the baseline matters more than
  # the chart that draws it.
  class HistoryTest < ActiveSupport::TestCase
    def day(date, processed, failed) = Day.new(date: date, processed: processed, failed: failed)

    def test_failure_rate_is_a_share_of_the_days_work
      assert_in_delta 0.01, day("2026-01-01", 990, 10).failure_rate, 0.0001
      assert_in_delta 0.5,  day("2026-01-01", 1, 1).failure_rate, 0.0001
    end

    # Counts move with traffic, so a busy Monday looks worse than a quiet Sunday
    # even when nothing changed. A rate does not, which is why it is the line.
    def test_a_busier_day_with_the_same_rate_reads_the_same
      assert_in_delta day("a", 100, 1).failure_rate, day("b", 10_000, 100).failure_rate, 0.0001
    end

    def test_a_day_with_no_work_has_no_rate_rather_than_dividing_by_zero
      assert_equal 0.0, day("2026-01-01", 0, 0).failure_rate
      assert day("2026-01-01", 0, 0).quiet?
    end

    def test_a_day_of_pure_failure_is_total
      assert_in_delta 1.0, day("2026-01-01", 0, 5).failure_rate, 0.0001
    end

    # The median, not the mean: one incident day would drag a mean up and make
    # the following week look calm by comparison.
    def test_the_baseline_is_a_median_so_one_bad_day_cannot_move_it
      days = [ day("1", 1000, 2), day("2", 1000, 2), day("3", 1000, 2), day("4", 1000, 900) ]
      typical = History.typical_failure_rate(days)
      assert_in_delta 0.002, typical, 0.0005, "an incident day must not become the baseline"
    end

    # Quiet days would otherwise pull the baseline to zero and make every working
    # day look like a regression.
    def test_quiet_days_are_excluded_from_the_baseline
      days = [ day("1", 0, 0), day("2", 0, 0), day("3", 1000, 10) ]
      assert_in_delta 0.0099, History.typical_failure_rate(days), 0.001
    end

    def test_no_usable_days_means_no_baseline_rather_than_zero
      assert_nil History.typical_failure_rate([])
      assert_nil History.typical_failure_rate([ day("1", 0, 0) ])
    end

    def test_the_window_is_clamped_to_something_sidekiq_actually_keeps
      assert_equal 1, History.clamp(0)
      assert_equal 1, History.clamp(-30)
      assert_equal History::MAX_DAYS, History.clamp(9_999)
      assert_equal 30, History.clamp("30")
    end

    # Solid Queue has no equivalent, so the section must hide rather than draw an
    # empty chart.
    def test_a_backend_without_history_returns_nothing
      backend = Object.new
      backend.define_singleton_method(:supports?) { |_| false }
      assert_empty History.days(30, backend: backend)
    end

    def test_a_raising_backend_degrades_to_no_history
      backend = Object.new
      backend.define_singleton_method(:supports?) { |_| true }
      backend.define_singleton_method(:history) { |_| raise "redis gone" }
      assert_empty History.days(30, backend: backend)
    end
  end

  class HistoryRenderingTest < ActionDispatch::IntegrationTest
    # Stats::History reads stat:processed:<date> keys, so seed a few days of them.
    def seed_history(fake, days: 5)
      days.times do |i|
        date = (Date.today - i).strftime("%Y-%m-%d")
        fake.call("SET", "stat:processed:#{date}", (900 + i).to_s)
        fake.call("SET", "stat:failed:#{date}", (i * 3).to_s)
      end
    end

    def test_the_dashboard_carries_the_series_and_a_baseline
      with_fake_redis { |fake| seed_history(fake); get "/roundhouse" }
      assert_response :success
      assert_select "canvas#rh-history[data-rh-history]"
      assert_select "canvas#rh-history[data-rh-typical]"
    end

    # The range has to survive a reload and be linkable, so it lives in the URL.
    def test_the_range_comes_from_the_url
      with_fake_redis { |fake| seed_history(fake); get "/roundhouse", params: { history: "7" } }
      assert_response :success
      assert_select "a.rh-qf.is-on", text: "1 week"
    end

    # A hostile or absurd range must not reach Sidekiq's API unbounded.
    def test_an_absurd_range_is_clamped
      get "/roundhouse", params: { history: "99999" }
      assert_response :success
      get "/roundhouse", params: { history: "-5" }
      assert_response :success
      get "/roundhouse", params: { history: "not a number" }
      assert_response :success
    end
  end
end
