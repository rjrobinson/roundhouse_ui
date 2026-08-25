require "test_helper"

module RoundhouseUi
  class HealthTest < ActiveSupport::TestCase
    FakeMetrics = Struct.new(:failure_ratio, :utilization, keyword_init: true)
    FakeQueue = Struct.new(:name, :latency)

    def health(failure_ratio: 0.0, utilization: nil, queues: [])
      Health.new(stats: nil, queues: queues,
                 metrics: FakeMetrics.new(failure_ratio: failure_ratio, utilization: utilization))
    end

    def test_all_clear_is_healthy
      h = health(failure_ratio: 0.001, utilization: 0.4, queues: [ FakeQueue.new("default", 2) ])
      assert_equal :ok, h.status
      assert h.healthy?
    end

    def test_stuck_queue_is_critical_and_named_in_the_reason
      h = health(queues: [ FakeQueue.new("ai", 846) ])
      assert_equal :crit, h.status
      assert_match "ai", h.reason
    end

    def test_elevated_error_rate_warns
      h = health(failure_ratio: 0.05)
      assert_equal :warn, h.status
    end

    def test_worst_signal_wins
      # warn-level error rate + crit-level latency → overall crit
      h = health(failure_ratio: 0.05, queues: [ FakeQueue.new("low", 700) ])
      assert_equal :crit, h.status
    end

    def test_saturated_utilization_is_critical
      assert_equal :crit, health(utilization: 1.0).status
    end

    def test_utilization_signal_omitted_when_no_workers_reporting
      h = health(utilization: nil)
      refute h.signals.any? { |s| s.key == "utilization" }
    end
  end
end

module RoundhouseUi
  # The banner's order is information: a failing check must never sit below a
  # healthy one, and the order must not shuffle between polls.
  class HealthRankingTest < ActiveSupport::TestCase
    def sig(status, label) = Health::Signal.new(key: label, label: label, status: status, detail: "d")

    def health_with(*signals)
      h = Health.new(stats: nil, queues: [], metrics: nil)
      h.define_singleton_method(:signals) { signals }
      h
    end

    def test_failing_checks_come_first
      h = health_with(sig(:ok, "Error rate"), sig(:crit, "Queue latency"), sig(:warn, "Utilization"))
      assert_equal [ "Queue latency", "Utilization", "Error rate" ], h.ranked_signals.map(&:label)
    end

    # Same statuses must produce the same order every poll, or the banner
    # reshuffles under the reader for no reason.
    def test_ties_break_on_label_so_the_order_is_stable
      h = health_with(sig(:crit, "Zebra"), sig(:crit, "Alpha"))
      assert_equal %w[Alpha Zebra], h.ranked_signals.map(&:label)
      assert_equal h.ranked_signals.map(&:label), h.ranked_signals.map(&:label)
    end

    def test_failing_count_ignores_healthy_checks
      h = health_with(sig(:ok, "a"), sig(:ok, "b"), sig(:crit, "c"))
      assert_equal 1, h.failing_count
    end

    def test_all_healthy_reports_nothing_failing
      h = health_with(sig(:ok, "a"), sig(:ok, "b"))
      assert_equal 0, h.failing_count
    end

    def test_an_unknown_status_does_not_crash_the_ranking
      h = health_with(sig(:ok, "a"), sig(:mystery, "b"))
      assert_equal 2, h.ranked_signals.size
    end
  end

  class HealthBannerRenderingTest < ActionDispatch::IntegrationTest
    # There is no disclosure any more: three rows do not need collapsing, and
    # hiding the signals hides the answer someone came for.
    def test_the_signals_are_not_behind_a_disclosure
      get "/roundhouse"
      assert_response :success
      assert_select "section.rh-health"
      assert_select "details.rh-health", count: 0
      refute_match "why ▾", @response.body
    end

    def test_each_signal_is_its_own_tile_with_a_severity
      get "/roundhouse"
      assert_select ".rh-health-signals .rh-sig[data-rh-sev]", minimum: 1
    end

    def test_the_header_states_how_many_checks_are_failing
      get "/roundhouse"
      assert_match(/\d+ checks?/, @response.body)
    end
  end
end
