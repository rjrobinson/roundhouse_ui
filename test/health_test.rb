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
