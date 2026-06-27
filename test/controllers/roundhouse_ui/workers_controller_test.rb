require "test_helper"

module RoundhouseUi
  class WorkersControllerTest < ActionDispatch::IntegrationTest
    # Stand-ins for Sidekiq::Process / Sidekiq::ProcessSet so the test needs no Redis.
    class FakeProcess
      attr_reader :identity, :actions
      def initialize(data, identity:)
        @data, @identity, @actions = data, identity, []
      end
      def [](key) = @data[key]
      def quiet? = @actions.include?(:quiet)
      def stopping? = @actions.include?(:stop)
      def quiet! = @actions << :quiet
      def stop! = @actions << :stop
    end

    class FakeProcessSet
      include Enumerable
      def initialize(processes) = @processes = processes
      def each(&blk) = @processes.each(&blk)
    end

    def setup
      RoundhouseUi.read_only = false
      now = Time.now.to_f
      @process = FakeProcess.new(
        {
          "hostname" => "worker-01", "pid" => 4821, "concurrency" => 10, "busy" => 3,
          "queues" => %w[default low], "started_at" => now - 3600, "beat" => now,
          "version" => "8.1.6", "tag" => "trainual", "rss" => 412_000
        },
        identity: "worker-01:4821:abc"
      )
      @set = FakeProcessSet.new([ @process ])
    end

    def teardown = RoundhouseUi.read_only = false

    def test_index_lists_running_processes
      stub_method(Sidekiq::ProcessSet, :new, @set) do
        get "/roundhouse/workers"

        assert_response :success
        assert_match "worker-01", @response.body
        assert_match "default, low", @response.body
        assert_match "3/10", @response.body
      end
    end

    def test_shows_pause_aware_fetch_indicator_when_fetcher_active
      with_fake_redis do
        Pause.mark_fetch_alive!
        stub_method(Sidekiq::ProcessSet, :new, @set) do
          get "/roundhouse/workers"
          assert_response :success
          assert_match "pause-aware", @response.body
        end
      end
    end

    def test_quiet_signals_the_process
      stub_method(Sidekiq::ProcessSet, :new, @set) do
        post "/roundhouse/workers/quiet", params: { identity: "worker-01:4821:abc" }
      end
      assert_response :redirect
      assert_includes @process.actions, :quiet
    end

    def test_stop_signals_the_process
      stub_method(Sidekiq::ProcessSet, :new, @set) do
        post "/roundhouse/workers/stop", params: { identity: "worker-01:4821:abc" }
      end
      assert_response :redirect
      assert_includes @process.actions, :stop
    end

    def test_read_only_mode_blocks_signals
      RoundhouseUi.read_only = true
      stub_method(Sidekiq::ProcessSet, :new, @set) do
        post "/roundhouse/workers/quiet", params: { identity: "worker-01:4821:abc" }
        post "/roundhouse/workers/stop", params: { identity: "worker-01:4821:abc" }
      end
      assert_empty @process.actions
    end
  end
end
