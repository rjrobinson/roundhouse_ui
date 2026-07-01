require "test_helper"

module RoundhouseUi
  class DurationCollectorTest < ActiveSupport::TestCase
    # A Redis stand-in that understands the hash commands the collector uses.
    class HashRedis
      attr_reader :h
      def initialize(seed = {}) = @h = seed.dup
      def call(cmd, *args)
        case cmd.to_s.upcase
        when "HINCRBY"      then _, f, by = args; @h[f] = @h.fetch(f, 0).to_i + by.to_i
        when "HINCRBYFLOAT" then _, f, by = args; @h[f] = @h.fetch(f, 0).to_f + by.to_f
        when "HGETALL"      then @h.flat_map { |k, v| [ k, v.to_s ] }
        else raise "HashRedis: unexpected #{cmd}"
        end
      end
    end

    def with_redis(fake)
      original = Sidekiq.method(:redis)
      Sidekiq.define_singleton_method(:redis) { |&blk| blk.call(fake) }
      yield
    ensure
      Sidekiq.define_singleton_method(:redis, original)
    end

    def test_middleware_records_a_run_and_yields
      fake = HashRedis.new
      ran = false
      with_redis(fake) do
        DurationCollector.new.call(nil, { "class" => "DemoJob" }, nil) { ran = true }
      end
      assert ran, "middleware must yield to the job"
      assert_equal 1, fake.h["DemoJob\x00count"]
      assert fake.h["DemoJob\x00ms"] >= 0
    end

    def test_summary_sorts_slowest_by_total_time_and_computes_avg
      seed = {
        "SlowJob\x00count" => 2,  "SlowJob\x00ms" => 3000.0,
        "FastJob\x00count" => 10, "FastJob\x00ms" => 500.0
      }
      with_redis(HashRedis.new(seed)) do
        summary = DurationCollector.summary
        assert_equal "SlowJob", summary.first[:klass]   # 3000ms total > 500ms
        assert_equal 1500.0, summary.first[:avg_ms]
        assert_equal 2, summary.first[:count]
        assert_equal "FastJob", summary.last[:klass]
        assert_equal 50.0, summary.last[:avg_ms]
      end
    end
  end
end
