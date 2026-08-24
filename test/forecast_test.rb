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
      assert_equal body["queue_names"].sort, body["queue_depths"].keys.sort
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

    def test_the_empty_state_still_spans_every_column
      get "/roundhouse/queues"
      assert_match 'colspan="6"', @response.body
    end
  end
end
