require "test_helper"

module RoundhouseUi
  # The Solid Queue deployment that actually exists: no Redis anywhere.
  #
  # Every other test runs with a fake Redis installed over Sidekiq.redis, so a code
  # path that reaches for Redis on a Solid Queue install looks fine. That is how a
  # Snapshot button that captured nothing, an Audit link that raised from the sidebar,
  # and an Entry#retry that was never defined all shipped in 0.10.0.
  #
  # Redis is pointed at a closed port rather than assumed absent, so this proves the
  # same thing on a laptop with Redis running as it does in the CI lane without one.
  class SolidQueueNoRedisTest < ActionDispatch::IntegrationTest
    self.fake_redis = false

    class NoRedis < StandardError; end

    def setup
      [ ::SolidQueue::FailedExecution, ::SolidQueue::ScheduledExecution,
        ::SolidQueue::ReadyExecution, ::SolidQueue::Pause, ::SolidQueue::Job ].each(&:delete_all)
      @forgery = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = false
      # Sidekiq.redis raises, rather than reconfiguring the client to an unreachable
      # URL: configure_client does not rebuild an already-memoized pool on Sidekiq
      # 7/8, so the pool kept working and this suite passed against CI's Redis while
      # claiming there was none. Same technique test_helper uses to install its fake.
      @real_redis = Sidekiq.method(:redis)
      Sidekiq.define_singleton_method(:redis) { |&_blk| raise NoRedis, "no Redis on this install" }
      RoundhouseUi.read_only = false
      RoundhouseUi.backend = Backends::SolidQueue.new
    end

    def teardown
      ActionController::Base.allow_forgery_protection = @forgery
      Sidekiq.define_singleton_method(:redis, @real_redis) if @real_redis
      RoundhouseUi.backend = nil
    end

    # Guards every other test here: if Redis were reachable, they would prove nothing.
    def test_redis_really_is_unreachable
      assert_raises(NoRedis) { Sidekiq.redis { |c| c.call("PING") } }
    end

    def job_on(queue, klass: "HardJob", failed: false, scheduled_at: nil)
      job = ::SolidQueue::Job.create!(class_name: klass, queue_name: queue,
                                      arguments: { "arguments" => [ 1 ] },
                                      scheduled_at: scheduled_at)
      if failed
        ::SolidQueue::ReadyExecution.where(job_id: job.id).delete_all
        ::SolidQueue::FailedExecution.create!(job: job,
          error: { "exception_class" => "Boom", "message" => "kaboom" })
      end
      job
    end

    READ_PAGES = %w[
      /roundhouse /roundhouse/queues /roundhouse/dead /roundhouse/scheduled
      /roundhouse/busy /roundhouse/errors /roundhouse/metrics /roundhouse/settings
    ].freeze

    def test_every_page_renders_without_redis
      job_on("default", failed: true)
      READ_PAGES.each do |path|
        get path
        assert_response :success, "#{path} needs Redis to render"
      end
    end

    # ── the mutating paths, each asserted by its effect on Solid Queue's tables ──

    def test_pause_and_resume
      job_on("mailers")
      post "/roundhouse/queues/mailers/pause"
      assert_response :redirect
      assert_includes ::SolidQueue::Pause.pluck(:queue_name), "mailers"

      post "/roundhouse/queues/mailers/resume"
      assert_response :redirect
      refute_includes ::SolidQueue::Pause.pluck(:queue_name), "mailers"
    end

    def test_purge_a_queue
      2.times { job_on("bulky") }
      assert_equal 2, ::SolidQueue::ReadyExecution.where(queue_name: "bulky").count

      post "/roundhouse/queues/bulky/purge"
      assert_response :redirect
      assert_equal 0, ::SolidQueue::ReadyExecution.where(queue_name: "bulky").count
    end

    def test_delete_one_dead_job
      job_on("default", failed: true)
      jid = RoundhouseUi.backend.dead_set.first.jid

      post "/roundhouse/dead/#{jid}/delete"
      assert_response :redirect
      assert_equal 0, ::SolidQueue::FailedExecution.count
    end

    def test_retry_one_dead_job_puts_it_back_on_its_queue
      job_on("default", failed: true)
      entry = RoundhouseUi.backend.dead_set.first

      post "/roundhouse/dead/#{entry.jid}/retry"
      assert_response :redirect
      assert_equal 0, ::SolidQueue::FailedExecution.count, "the failure should be cleared"
      assert_equal 1, ::SolidQueue::ReadyExecution.where(job_id: entry.jid).count,
        "retry must re-enqueue, not just delete"
    end

    def test_bulk_delete_on_a_filter_takes_only_the_matches
      job_on("default", klass: "AlphaJob", failed: true)
      job_on("default", klass: "AlphaJob", failed: true)
      job_on("default", klass: "BetaJob",  failed: true)

      post "/roundhouse/dead/bulk_all", params: { op: "delete", q: "class=AlphaJob" }
      assert_response :redirect
      assert_equal [ "BetaJob" ], ::SolidQueue::FailedExecution.includes(:job).map { |f| f.job.class_name }
    end

    def test_a_wildcard_bulk_delete_works_without_redis
      job_on("default", klass: "Alpha::One", failed: true)
      job_on("default", klass: "Alpha::Two", failed: true)
      job_on("default", klass: "Beta::One",  failed: true)

      post "/roundhouse/dead/bulk_all", params: { op: "delete", q: "class=Alpha%" }
      assert_response :redirect
      assert_equal [ "Beta::One" ], ::SolidQueue::FailedExecution.includes(:job).map { |f| f.job.class_name }
    end

    def test_delete_a_scheduled_job
      job_on("default", scheduled_at: 1.hour.from_now)
      jid = RoundhouseUi.backend.scheduled_set.first.jid

      post "/roundhouse/scheduled/#{jid}/delete"
      assert_response :redirect
      assert_equal 0, ::SolidQueue::ScheduledExecution.count
    end

    # ── and the gated ones refuse instead of raising a Redis error ──

    GATED = [
      [ :get,  "/roundhouse/snapshots" ],
      [ :post, "/roundhouse/queues/default/snapshot" ],
      [ :get,  "/roundhouse/audit" ],
      [ :get,  "/roundhouse/jobs/new" ],
      [ :post, "/roundhouse/scheduled/abc/enqueue" ]
    ].freeze

    def test_gated_controls_refuse_rather_than_hitting_redis
      GATED.each do |verb, path|
        send(verb, path)
        assert_response :redirect, "#{verb.to_s.upcase} #{path} was not gated"
        follow_redirect!
        assert_response :success, "#{path} refused, then its redirect target needed Redis"
        assert_match(/is not available on this backend/, @response.body)
      end
    end

    def test_read_only_still_refuses_writes
      RoundhouseUi.read_only = true
      job_on("mailers")
      post "/roundhouse/queues/mailers/pause"
      assert_response :redirect
      refute_includes ::SolidQueue::Pause.pluck(:queue_name), "mailers",
        "read-only must hold with no Redis to check it against"
    ensure
      RoundhouseUi.read_only = false
    end
  end
end
