require "test_helper"

module RoundhouseUi
  class MetricsControllerTest < ActionDispatch::IntegrationTest
    def fake_stats
      Struct.new(
        :processed, :failed, :enqueued, :scheduled_size,
        :retry_size, :dead_size, :workers_size
      ).new(8_420_118, 1_724, 10_641, 3_201, 218, 1_506, 47)
    end

    # One process with 50 worker threads, so utilization = 47 / 50 = 94%.
    def fake_processes
      [ { "concurrency" => 50 } ]
    end

    def test_renders_derived_capacity_metrics
      stub_method(Sidekiq::Stats, :new, fake_stats) do
        stub_method(Sidekiq::ProcessSet, :new, fake_processes) do
          get "/roundhouse/metrics"

          assert_response :success
          assert_match "Utilization", @response.body
          assert_match "94%", @response.body          # 47 busy / 50 threads
          assert_match "Idle headroom", @response.body
          assert_match "Backlog", @response.body
          assert_match "Failure ratio", @response.body

          # Live-rate cards the poll fills client-side.
          assert_match 'id="rh-m-throughput"', @response.body
          assert_match 'id="rh-m-failrate"', @response.body
          assert_match 'id="rh-m-velocity"', @response.body
          assert_match 'id="rh-m-eta"', @response.body
        end
      end
    end
  end
end
