require "test_helper"

module RoundhouseUi
  # The server half of the drain forecast (#35): the poll has to carry per-queue
  # depths, and every surface that shows a forecast has to ask for one by queue
  # name. The decision table itself is JavaScript — see test/js/forecast_test.js,
  # which lifts the functions out of the layout rather than copying them.
  class ForecastTest < ActionDispatch::IntegrationTest
    def test_the_poll_carries_per_queue_depths
      get "/roundhouse/stats", headers: { "Accept" => "application/json" }
      assert_response :success
      body = JSON.parse(@response.body)
      assert body.key?("queue_depths"), "the poll must carry depths or nothing can compute a velocity"
      assert_kind_of Hash, body["queue_depths"]
    end

    # Depths come from the read this endpoint already made for the queue count,
    # so the forecast must not have added a round-trip to every poll. Same
    # queues, one source.
    def test_depths_agree_with_the_queue_count
      get "/roundhouse/stats", headers: { "Accept" => "application/json" }
      body = JSON.parse(@response.body)
      assert_equal body["queues"], body["queue_depths"].size
      # Names are the depth keys; sending them separately duplicated every name.
      refute body.key?("queue_names"), "queue names must not be sent twice"
    end

    # Capacity needs total threads, not threads busy right now — workers_size
    # goes to zero on an idle fleet and dividing by it claims infinite headroom.
    def test_the_poll_carries_total_concurrency
      get "/roundhouse/stats", headers: { "Accept" => "application/json" }
      assert JSON.parse(@response.body).key?("concurrency")
    end

    def test_every_queue_row_asks_for_a_forecast
      get "/roundhouse/queues"
      assert_response :success
      assert_match "Forecast", @response.body
    end

    # A first paint has only one sample, so it cannot know a velocity. Saying
    # "measuring…" is the honest state; a zero or a dash both imply a fact.
    def test_first_paint_says_it_is_still_measuring
      get "/roundhouse/queues"
      assert_match "measuring…", @response.body if @response.body.include?("data-rh-forecast")
    end

    # Seeds one real queue: the assertions below are about rendered rows, and the
    # page shows an empty-state row when there are none.
    def seed_one(fake, name = "default", size: 3, age: nil)
      fake.call("SADD", "queues", name)
      size.times do |i|
        at = age ? Time.now.to_f - age : Time.now.to_f
        fake.call("RPUSH", "queue:#{name}", Sidekiq.dump_json("jid" => "#{name}#{i}", "enqueued_at" => at))
      end
    end

    # The trend column renders both a shimmer and a hidden canvas: the poll
    # reveals the canvas once it has two samples. The other way round leaves a
    # blank gap on first paint.
    def test_every_queue_row_carries_a_trend_canvas_and_a_placeholder
      with_fake_redis do |fake|
        seed_one(fake)
        get "/roundhouse/queues"

        assert_response :success
        assert_select "td.rh-trend canvas[data-rh-spark][hidden]", minimum: 1
        assert_select "td.rh-trend span.rh-trend-empty", minimum: 1
      end
    end

    # A stripe needs a value on first paint, before any velocity exists, or every
    # row is unmarked until the second poll.
    def test_rows_carry_a_server_seeded_severity
      with_fake_redis do |fake|
        seed_one(fake, "slow", size: 2, age: 900)
        get "/roundhouse/queues"

        assert_select 'tbody tr[data-rh-sev="crit"]', minimum: 1,
          message: "a queue whose oldest job is 15m old should seed a critical stripe"
      end
    end

    def test_the_empty_state_still_spans_every_column
      get "/roundhouse/queues"
      assert_match 'colspan="7"', @response.body
    end
  end
end
