require "test_helper"

module RoundhouseUi
  class DashboardControllerTest < ActionDispatch::IntegrationTest
    def fake_stats
      Struct.new(
        :processed, :failed, :enqueued, :scheduled_size,
        :retry_size, :dead_size, :workers_size
      ).new(8_420_118, 1_724, 10_641, 3_201, 218, 1_506, 47)
    end

    class FakeSet
      include Enumerable
      def initialize(items = []) = @items = items
      def each(&blk) = @items.each(&blk)
    end

    # The dashboard #show reads Stats + Queue, plus ProcessSet (utilization) and
    # the retry/dead sets (top failing classes) — stub them all so it renders
    # without a live Redis.
    def stub_dashboard(&blk)
      stub_method(Sidekiq::Stats, :new, fake_stats) do
        stub_method(Sidekiq::Queue, :all, []) do
          stub_method(Sidekiq::ProcessSet, :new, FakeSet.new) do
            stub_method(Sidekiq::RetrySet, :new, FakeSet.new) do
              stub_method(Sidekiq::DeadSet, :new, FakeSet.new, &blk)
            end
          end
        end
      end
    end

    # Proves the engine mounts, the controller reads Sidekiq::Stats, the view
    # renders, and the live-update hooks are present.
    def test_dashboard_renders_real_sidekiq_stats
      stub_dashboard do
        get "/roundhouse"

        assert_response :success
        assert_match "Roundhouse", @response.body
        assert_match "8,420,118", @response.body          # processed, delimited
        assert_match "No active queues", @response.body
        assert_match 'data-stat="processed"', @response.body # live-update hook
        assert_match "/roundhouse/stats", @response.body     # poll endpoint wired
        assert_match 'id="rh-palette"', @response.body       # ⌘K command palette present
        assert_match "/roundhouse/turbo.js", @response.body  # Turbo loaded
        assert_match "Healthy", @response.body               # composite health verdict
      end
    end

    def test_response_carries_a_self_contained_nonce_csp
      stub_dashboard do
        get "/roundhouse"

        csp = @response.headers["Content-Security-Policy"]
        assert csp.present?, "engine sets its own CSP"
        assert_match "script-src", csp
        assert_match(/'nonce-/, csp, "script-src is nonce-based")
        assert_match(/<script nonce="[^"]+"/, @response.body, "inline poll script is nonce'd")
      end
    end

    def test_stats_endpoint_returns_live_counts_as_json
      stub_method(Sidekiq::Stats, :new, fake_stats) do
        stub_method(Sidekiq::Queue, :all, []) do
          get "/roundhouse/stats"

          assert_response :success
          assert_equal "application/json", @response.media_type
          body = JSON.parse(@response.body)
          assert_equal 8_420_118, body["processed"]
          assert_equal 47, body["busy"]
          assert_equal 1_506, body["dead"]
        end
      end
    end
  end
end
