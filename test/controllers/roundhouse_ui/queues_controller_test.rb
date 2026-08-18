require "test_helper"

module RoundhouseUi
  class QueuesControllerTest < ActionDispatch::IntegrationTest
    # Seed real Redis keys rather than stubbing Sidekiq::Queue: the page now reads
    # every queue's depth and latency in one pipelined batch, so stubbing the
    # Queue objects would skip the code under test entirely.
    def seed_queue(fake, name, size: 0, age: nil)
      fake.call("SADD", "queues", name)
      size.times do |i|
        enqueued = age ? Time.now.to_f - age : Time.now.to_f
        fake.call("RPUSH", "queue:#{name}", Sidekiq.dump_json("jid" => "#{name}#{i}", "enqueued_at" => enqueued))
      end
    end

    def setup = RoundhouseUi.read_only = false
    def teardown = RoundhouseUi.read_only = false

    def test_index_lists_queues_with_paused_state_and_controls
      with_fake_redis do |_fake_redis|
        Pause.pause!("low")
        seed_queue(_fake_redis, "default", size: 2)
        seed_queue(_fake_redis, "low", size: 3, age: 846)
        get "/roundhouse/queues"

        assert_response :success
        assert_match "default", @response.body
        assert_match "paused", @response.body  # low is paused
        assert_match "Resume", @response.body  # control for the paused queue
        assert_match "Pause", @response.body   # control for the active queue
        assert_match "5 waiting", @response.body, "the heading should total every queue"
        # 846s must not render as raw seconds
        assert_match "14m", @response.body
      end
    end

    def test_index_warns_when_fetcher_not_installed
      with_fake_redis do
        get "/roundhouse/queues"
        assert_match "not enforced", @response.body
        assert_match "RoundhouseUi::Fetch", @response.body
      end
    end

    def test_pause_disabled_hides_warning_and_controls
      RoundhouseUi.pause_enabled = false
      with_fake_redis do |_fake_redis|
        seed_queue(_fake_redis, "default", size: 1)
        get "/roundhouse/queues"

        assert_response :success
        assert_match "default", @response.body      # queue still listed
        assert_match "Purge", @response.body         # non-pause controls remain
        refute_match "not enforced", @response.body  # warning suppressed
        refute_match "Pause", @response.body          # pause control hidden
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
