require "test_helper"

module RoundhouseUi
  # Each page gets the visual that answers its own question rather than a
  # sparkline everywhere. These pin the parts a reader cannot verify by eye:
  # that a proportion is computed against the right denominator, and that a
  # missing baseline degrades rather than lies.
  class PageVisualsTest < ActiveSupport::TestCase
    include RoundhouseUi::ApplicationHelper

    include ActionView::Helpers::DateHelper
    include ActionView::Helpers::TagHelper
    include ActionView::Helpers::OutputSafetyHelper
    include ActionView::Helpers::UrlHelper

    def test_the_attempt_ladder_fills_one_rung_per_attempt
      html = attempt_ladder(3)
      assert_equal 3, html.scan(/class="is-(?:on|hot)"/).size
      assert_includes html, "3/25"
    end

    # A job on its twenty-first attempt is nearly out of them; that has to look
    # different from one on its third, not merely say a bigger number.
    def test_a_high_attempt_count_turns_hot
      refute_includes attempt_ladder(3), "is-hot"
      assert_includes attempt_ladder(21), "is-hot"
    end

    def test_the_ladder_cannot_overflow_its_track
      html = attempt_ladder(400)
      assert_equal 25, html.scan(/<i/).size
      assert_includes html, "25/25"
    end

    def test_a_zero_attempt_ladder_is_empty_not_broken
      html = attempt_ladder(0)
      assert_equal 25, html.scan(/<i/).size
      refute_includes html, "is-on"
    end

    # The ring shows progress THROUGH the wait. Without a start time there is no
    # fraction to show, and inventing one would be a lie about how soon it fires.
    def test_the_countdown_ring_needs_a_start_time_to_show_progress
      at = Time.now + 60
      assert_includes countdown(at, since: Time.now - 60), "--rh-turn:0.5turn"
      assert_includes countdown(at), "--rh-turn:0.0turn"
    end

    def test_an_overdue_job_shows_a_full_ring
      assert_includes countdown(Time.now - 5, since: Time.now - 60), "--rh-turn:1.0turn"
    end

    def test_no_scheduled_time_renders_a_dash_rather_than_a_ring
      assert_equal "<span class=\"rh-sub\">—</span>", countdown(nil)
    end
  end

  class DashboardCardTrendsTest < ActionDispatch::IntegrationTest
    # A blind insertion put one of these inside the Problem-queues panel instead
    # of its card, where it rendered a stray 26px canvas and no trend.
    def test_every_card_trend_sits_inside_a_card
      get "/roundhouse"
      assert_response :success
      assert_select ".rh-card canvas[data-rh-card]", count: 4
      assert_select ".rh-insight canvas[data-rh-card]", count: 0
    end

    # The four keys the poll knows how to compute. A canvas naming anything else
    # silently draws nothing.
    def test_the_card_keys_match_what_the_poll_can_supply
      get "/roundhouse"
      keys = @response.body.scan(/data-rh-card="(\w+)"/).flatten.sort
      assert_equal %w[backlog busy failed processed], keys
    end
  end

  class BusyBaselineTest < ActionDispatch::IntegrationTest
    def teardown = RoundhouseUi.collect_durations = false

    # Without the collector there is no typical duration, so the bar must show
    # elapsed with no ceiling rather than implying a comparison it cannot make.
    def test_no_collector_means_no_baseline_claim
      RoundhouseUi.collect_durations = false
      get "/roundhouse/busy"
      assert_response :success
      refute_match "no baseline", @response.body
    end

    # With the collector enabled but nothing recorded yet, saying so is better
    # than showing a ratio against zero.
    def test_collector_enabled_but_empty_says_so
      RoundhouseUi.collect_durations = true
      get "/roundhouse/busy"
      assert_response :success
    end
  end
end
