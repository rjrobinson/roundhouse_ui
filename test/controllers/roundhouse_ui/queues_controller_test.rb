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

    # Filtering by state. A paused queue is the most common thing someone is
    # hunting for here — it is why work is not moving.
    def test_filters_to_paused_queues
      with_fake_redis do |fake|
        Pause.pause!("low")
        seed_queue(fake, "default", size: 2)
        seed_queue(fake, "low", size: 3)
        get "/roundhouse/queues", params: { state: "paused" }

        assert_response :success
        assert_match ">low<", @response.body
        refute_match ">default<", @response.body
      end
    end

    def test_filters_to_active_queues
      with_fake_redis do |fake|
        Pause.pause!("low")
        seed_queue(fake, "default", size: 2)
        seed_queue(fake, "low", size: 3)
        get "/roundhouse/queues", params: { state: "active" }

        assert_match ">default<", @response.body
        refute_match ">low<", @response.body
      end
    end

    # Counts come from the unfiltered set: a chip that reads "0" once you have
    # selected it gives you no way back.
    def test_state_counts_are_not_themselves_filtered
      with_fake_redis do |fake|
        Pause.pause!("low")
        seed_queue(fake, "default", size: 2)
        seed_queue(fake, "low", size: 3)
        get "/roundhouse/queues", params: { state: "paused" }

        assert_match %r{Active\s*<span class="rh-qf-n">1</span>}, @response.body
        assert_match %r{Paused\s*<span class="rh-qf-n">1</span>}, @response.body
      end
    end

    # Filtering by a state you cannot set is a dead end.
    def test_no_state_chips_when_pausing_is_disabled
      with_fake_redis do |fake|
        seed_queue(fake, "default", size: 1)
        RoundhouseUi.pause_enabled = false
        get "/roundhouse/queues"
        refute_match "state=paused", @response.body
      end
    ensure
      RoundhouseUi.pause_enabled = true
    end

    # Sorting is client-side because the Forecast column has no server-side
    # value at all, so every sortable column must carry one the JS can compare —
    # "3h 19m" cannot be parsed back into seconds.
    def test_sortable_columns_carry_comparable_values
      with_fake_redis do |fake|
        seed_queue(fake, "default", size: 7, age: 846)
        get "/roundhouse/queues"

        assert_match 'data-sort-col="0"', @response.body
        assert_match 'data-sort-type="num"', @response.body
        assert_match 'data-sort-value="7"', @response.body, "size needs its raw number"
        assert_match 'data-sort-value="default"', @response.body
      end
    end
  end
end
