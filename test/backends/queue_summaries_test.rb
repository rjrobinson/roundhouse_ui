require "test_helper"

module RoundhouseUi
  # The Queues page used to cost a Redis round-trip per queue per column: on an
  # app with sixty queues that was most of a page render. These pin the batched
  # read so it cannot quietly go back to N+1.
  class QueueSummariesTest < ActiveSupport::TestCase
    class CountingRedis
      attr_reader :calls
      def initialize(inner)
        @inner = inner
        @calls = 0
      end

      def call(cmd, *args)
        @calls += 1
        @inner.call(cmd, *args)
      end

      # One pipeline is one round-trip however many commands ride in it.
      def pipelined
        @calls += 1
        collector = Collector.new(@inner)
        yield collector
        collector.replies
      end

      class Collector
        attr_reader :replies
        def initialize(inner)
          @inner = inner
          @replies = []
        end
        def call(cmd, *args) = @replies << @inner.call(cmd, *args)
      end
    end

    def with_counting_redis(seed)
      fake = ActiveSupport::TestCase::FakeRedis.new
      seed.each do |name, jobs|
        fake.call("SADD", "queues", name)
        # Sidekiq enqueues with LPUSH and fetches from the tail, so seeding in
        # chronological order leaves the OLDEST job at index -1 — which is what
        # latency is measured from.
        jobs.each { |j| fake.call("LPUSH", "queue:#{name}", Sidekiq.dump_json(j)) }
      end
      counting = CountingRedis.new(fake)
      original = Sidekiq.method(:redis)
      Sidekiq.define_singleton_method(:redis) { |&blk| blk.call(counting) }
      yield counting
    ensure
      Sidekiq.define_singleton_method(:redis, original)
    end

    def test_reads_every_queue_in_a_constant_number_of_round_trips
      seed = 12.times.to_h { |i| [ "q#{i}", [ { "jid" => "a", "enqueued_at" => Time.now.to_f } ] ] }
      with_counting_redis(seed) do |conn|
        summaries = Backends::Sidekiq.new.queue_summaries
        assert_equal 12, summaries.size
        assert_equal 2, conn.calls,
          "one SMEMBERS plus one pipeline — cost must not scale with queue count"
      end
    end

    def test_reports_size_and_latency_per_queue
      now = Time.now.to_f
      seed = {
        "busy" => [ { "jid" => "a", "enqueued_at" => now - 500 }, { "jid" => "b", "enqueued_at" => now - 10 } ],
        "idle" => []
      }
      with_counting_redis(seed) do
        by_name = Backends::Sidekiq.new.queue_summaries.to_h { |s| [ s.name, s ] }

        assert_equal 2, by_name["busy"].size
        # Latency is measured from the OLDEST job, which is the tail of the list.
        assert_in_delta 500, by_name["busy"].latency, 2
        assert_equal 0, by_name["idle"].size
        assert_equal 0.0, by_name["idle"].latency
      end
    end


    # Sidekiq 8 writes enqueued_at as integer epoch MILLISECONDS; 6.5 and 7 write
    # float epoch seconds. The gap is three orders of magnitude, so reading one as
    # the other does not give a slightly wrong latency — it gives nonsense. Both
    # formats are exercised because CI runs both Sidekiq generations.
    def test_reads_the_millisecond_timestamp_format_sidekiq_8_writes
      ms = ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond) - 90_000
      with_counting_redis("modern" => [ { "jid" => "a", "enqueued_at" => ms } ]) do
        summary = Backends::Sidekiq.new.queue_summaries.first
        assert_in_delta 90, summary.latency, 2, "integer ms must not be read as seconds"
        assert_operator summary.latency, :>, 0, "a past timestamp cannot yield negative latency"
      end
    end

    def test_reads_the_float_second_timestamp_format_older_sidekiq_writes
      with_counting_redis("legacy" => [ { "jid" => "a", "enqueued_at" => Time.now.to_f - 90 } ]) do
        assert_in_delta 90, Backends::Sidekiq.new.queue_summaries.first.latency, 2
      end
    end

    def test_a_missing_timestamp_reads_as_no_latency
      with_counting_redis("odd" => [ { "jid" => "a" } ]) do
        assert_equal 0.0, Backends::Sidekiq.new.queue_summaries.first.latency
      end
    end

    # A queue with nothing ready must still be listed — an operator has to be
    # able to pause or clear a queue that happens to be empty right now.
    def test_keeps_queues_that_have_no_ready_work
      with_counting_redis("drained" => []) do
        assert_equal [ "drained" ], Backends::Sidekiq.new.queue_summaries.map(&:name)
      end
    end

    def test_no_queues_means_no_reads_beyond_the_lookup
      with_counting_redis({}) do |conn|
        assert_empty Backends::Sidekiq.new.queue_summaries
        assert_equal 1, conn.calls, "nothing to batch, so no pipeline"
      end
    end

    # A payload that will not parse must not take the page down with it.
    def test_an_unparseable_payload_reads_as_no_latency
      fake = ActiveSupport::TestCase::FakeRedis.new
      fake.call("SADD", "queues", "broken")
      fake.call("RPUSH", "queue:broken", "{not json")
      original = Sidekiq.method(:redis)
      Sidekiq.define_singleton_method(:redis) { |&blk| blk.call(fake) }

      summary = Backends::Sidekiq.new.queue_summaries.first
      assert_equal 1, summary.size
      assert_equal 0.0, summary.latency
    ensure
      Sidekiq.define_singleton_method(:redis, original)
    end
  end
end
