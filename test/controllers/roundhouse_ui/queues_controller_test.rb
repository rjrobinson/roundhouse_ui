require "test_helper"

module RoundhouseUi
  class QueuesControllerTest < ActionDispatch::IntegrationTest
    FakeQueue = Struct.new(:name, :size, :latency)

    def setup = RoundhouseUi.read_only = false
    def teardown = RoundhouseUi.read_only = false

    def test_index_lists_queues_with_paused_state_and_controls
      with_fake_redis do
        Pause.pause!("low")
        queues = [ FakeQueue.new("default", 1_284, 2.3), FakeQueue.new("low", 8_932, 846.0) ]
        stub_method(Sidekiq::Queue, :all, queues) do
          get "/roundhouse/queues"

          assert_response :success
          assert_match "default", @response.body
          assert_match "8,932", @response.body
          assert_match "paused", @response.body  # low is paused
          assert_match "Resume", @response.body  # control for the paused queue
          assert_match "Pause", @response.body   # control for the active queue
        end
      end
    end

    def test_index_warns_when_fetcher_not_installed
      with_fake_redis do
        stub_method(Sidekiq::Queue, :all, []) do
          get "/roundhouse/queues"
          assert_match "not enforced", @response.body
          assert_match "RoundhouseUi::Fetch", @response.body
        end
      end
    end

    def test_pause_disabled_hides_warning_and_controls
      RoundhouseUi.pause_enabled = false
      with_fake_redis do
        queues = [ FakeQueue.new("default", 10, 1.0) ]
        stub_method(Sidekiq::Queue, :all, queues) do
          get "/roundhouse/queues"

          assert_response :success
          assert_match "default", @response.body      # queue still listed
          assert_match "Purge", @response.body         # non-pause controls remain
          refute_match "not enforced", @response.body  # warning suppressed
          refute_match "Pause", @response.body          # pause control hidden
        end
      end
    ensure
      RoundhouseUi.pause_enabled = true
    end

    def test_purge_clears_the_queue
      cleared = []
      fake = Object.new.tap { |o| o.define_singleton_method(:clear) { cleared << true } }
      stub_method(Sidekiq::Queue, :new, fake) do
        post "/roundhouse/queues/default/purge"
      end
      assert_response :redirect
      assert_includes @response.redirect_url, "/roundhouse/queues"
      assert_equal [ true ], cleared
    end

    def test_pause_then_resume_update_the_registry
      with_fake_redis do
        post "/roundhouse/queues/low/pause"
        assert Pause.paused?("low")
        post "/roundhouse/queues/low/resume"
        refute Pause.paused?("low")
      end
    end

    def test_read_only_mode_blocks_queue_actions
      RoundhouseUi.read_only = true
      with_fake_redis do
        post "/roundhouse/queues/low/pause"
        assert_response :redirect
        refute Pause.paused?("low"), "pause must not run in read-only mode"
      end
    end
  end
end
