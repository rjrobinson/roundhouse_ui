require "test_helper"

module RoundhouseUi
  class MetricsTest < ActiveSupport::TestCase
    FakeStats = Struct.new(
      :workers_size, :processed, :failed, :enqueued, :scheduled_size, :retry_size,
      keyword_init: true
    )

    def build(busy:, processed:, failed:, enqueued: 0, scheduled: 0, retrying: 0, concurrency: [])
      Metrics.new(
        stats: FakeStats.new(
          workers_size: busy, processed: processed, failed: failed,
          enqueued: enqueued, scheduled_size: scheduled, retry_size: retrying
        ),
        processes: concurrency.map { |c| { "concurrency" => c } }
      )
    end

    def test_concurrency_sums_across_the_fleet
      m = build(busy: 0, processed: 0, failed: 0, concurrency: [ 10, 15 ])
      assert_equal 25, m.concurrency
    end

    def test_utilization_is_busy_over_total_concurrency
      m = build(busy: 12, processed: 100, failed: 0, concurrency: [ 10, 15 ])
      assert_in_delta 12.0 / 25, m.utilization
      assert_equal 13, m.headroom
    end

    def test_utilization_nil_and_headroom_zero_when_no_capacity
      m = build(busy: 0, processed: 0, failed: 0, concurrency: [])
      assert_nil m.utilization
      assert_equal 0, m.headroom
    end

    def test_headroom_never_negative_when_busy_exceeds_reported_capacity
      m = build(busy: 30, processed: 0, failed: 0, concurrency: [ 25 ])
      assert_equal 0, m.headroom
    end

    def test_backlog_sums_enqueued_scheduled_and_retrying
      m = build(busy: 0, processed: 0, failed: 0, enqueued: 5, scheduled: 3, retrying: 2)
      assert_equal 10, m.backlog
    end

    def test_failure_ratio
      m = build(busy: 0, processed: 200, failed: 10)
      assert_in_delta 0.05, m.failure_ratio
    end

    def test_failure_ratio_zero_when_nothing_processed
      m = build(busy: 0, processed: 0, failed: 0)
      assert_equal 0.0, m.failure_ratio
    end
  end
end
