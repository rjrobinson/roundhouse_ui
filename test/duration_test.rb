require "test_helper"

module RoundhouseUi
  # One formatter, because five call sites formatted durations five ways and the
  # health signal reported an hour-old queue as "3616s" (#31). Lives on
  # RoundhouseUi rather than the view helper so lib/ can reach it.
  class DurationTest < ActiveSupport::TestCase
    def test_sub_minute_keeps_a_decimal
      assert_equal "0.4s", RoundhouseUi.duration(0.42)
      assert_equal "12.0s", RoundhouseUi.duration(12)
      assert_equal "59.9s", RoundhouseUi.duration(59.94)
    end

    def test_minutes_hours_and_days
      assert_equal "1m 0s", RoundhouseUi.duration(60)
      assert_equal "14m 6s", RoundhouseUi.duration(846)
      assert_equal "1h 0m", RoundhouseUi.duration(3616)
      assert_equal "2h 48m", RoundhouseUi.duration(10_058) # #31's "10058.0s"
      assert_equal "1d 0h", RoundhouseUi.duration(86_400)
      assert_equal "3d 4h", RoundhouseUi.duration(273_000)
    end

    # The reported bug, pinned: an hour-old queue read as a four-figure number of
    # seconds, which nobody parses as an hour.
    def test_the_reported_value
      assert_equal "1h 0m", RoundhouseUi.duration(3616)
      refute_includes RoundhouseUi.duration(3616), "3616"
    end

    def test_nil_is_a_dash_not_a_zero
      assert_equal "—", RoundhouseUi.duration(nil)
      assert_equal "—", RoundhouseUi.duration_ms(nil)
    end

    # Clock skew and a queue whose oldest job is timestamped in the future both
    # produce negatives; "-1.0s" reads as a bug in the UI rather than in the data.
    def test_negatives_do_not_leak_a_minus_sign
      assert_equal "1.0s", RoundhouseUi.duration(-1)
      assert_equal "5m 0s", RoundhouseUi.duration(-300)
    end

    def test_milliseconds_hand_off_at_a_second
      assert_equal "0ms", RoundhouseUi.duration_ms(0)
      assert_equal "999ms", RoundhouseUi.duration_ms(999)
      assert_equal "1.0s", RoundhouseUi.duration_ms(1_000)
      assert_equal "2h 48m", RoundhouseUi.duration_ms(10_058_000)
    end

    # The health signal is why this moved out of the view helper in the first
    # place: it is in lib/ and had no way to reach the formatter.
    def test_the_health_signal_reads_as_a_duration
      fake_metrics = Struct.new(:failure_ratio, :utilization).new(0.0, nil)
      queues = [ QueueSummary.new(name: "critical", size: 4, latency: 3616) ]
      signal = Health.new(stats: nil, queues: queues, metrics: fake_metrics)
                     .signals.find { |sig| sig.key == "latency" }
      assert_includes signal.detail, "1h 0m"
      refute_includes signal.detail, "3616"
    end
  end
end
