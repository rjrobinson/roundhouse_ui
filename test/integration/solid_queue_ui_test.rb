require "test_helper"

module RoundhouseUi
  # End-to-end: with the backend pointed at Solid Queue, the UI renders from
  # Solid Queue's tables and hides the sections Solid Queue doesn't have.
  class SolidQueueUiTest < ActionDispatch::IntegrationTest
    def setup
      [ ::SolidQueue::FailedExecution, ::SolidQueue::ScheduledExecution,
        ::SolidQueue::ReadyExecution, ::SolidQueue::Job ].each(&:delete_all)
      RoundhouseUi.backend = Backends::SolidQueue.new
    end

    def teardown
      RoundhouseUi.backend = nil # back to the default Sidekiq backend
    end

    def failed_job(klass:, queue: "default", error_class: "Boom")
      job = ::SolidQueue::Job.create!(class_name: klass, queue_name: queue,
                                      arguments: { "arguments" => [] })
      ::SolidQueue::ReadyExecution.where(job_id: job.id).delete_all # drop auto-dispatch
      ::SolidQueue::FailedExecution.create!(job: job,
        error: { "exception_class" => error_class, "message" => "kaboom" })
    end

    # Every capability the backend lacks, checked BOTH ways: the control is absent
    # from the page and the route refuses. Hiding a button while leaving the route
    # open is how an ungated bulk_all emptied a set once already.
    #
    # Table-driven, so a new gate that is only half-wired fails here.
    GATED = [
      { capability: :snapshots,   verb: :get,  path: "/roundhouse/snapshots",            marker: "snapshots_path" },
      { capability: :snapshots,   verb: :post, path: "/roundhouse/queues/default/snapshot" },
      { capability: :redis,       verb: :get,  path: "/roundhouse/audit",                marker: "audit_log_path" },
      { capability: :enqueue,     verb: :get,  path: "/roundhouse/jobs/new" },
      { capability: :enqueue_now, verb: :post, path: "/roundhouse/scheduled/abc/enqueue" }
    ].freeze

    def test_solid_queue_lacks_the_capabilities_these_gates_name
      GATED.map { |g| g[:capability] }.uniq.each do |capability|
        refute RoundhouseUi.backend.supports?(capability),
          "this test asserts #{capability} is gated, but the backend claims to support it"
      end
    end

    def test_every_gated_route_refuses_rather_than_raising
      GATED.each do |gate|
        send(gate[:verb], gate[:path])
        assert_response :redirect,
          "#{gate[:verb].to_s.upcase} #{gate[:path]} did not refuse — #{gate[:capability]} is ungated at the route"
        follow_redirect!
        assert_match(/is not available on this backend/, @response.body,
          "#{gate[:path]} redirected without saying why")
      end
    end

    def test_no_gated_control_is_rendered
      get "/roundhouse/queues"
      assert_response :success
      body = @response.body.split("</style>").last.to_s
      refute_match "/snapshot", body, "a Snapshot button that cannot snapshot"
      refute_match "/roundhouse/audit", body, "an Audit link that needs Redis"
      refute_match "/roundhouse/jobs/new", body, "an Enqueue link with no push"
    end

    def test_scheduled_does_not_offer_enqueue_now
      # Solid Queue auto-dispatches a ScheduledExecution for a future scheduled_at,
      # so creating one by hand hits the job_id unique index.
      ::SolidQueue::Job.create!(class_name: "LaterJob", queue_name: "default",
                                arguments: { "arguments" => [] },
                                scheduled_at: 1.hour.from_now)

      get "/roundhouse/scheduled"
      assert_response :success
      body = @response.body.split("</style>").last.to_s
      assert_match "LaterJob", body, "the row must still render; only the control is gated"
      refute_match "Enqueue now", body, "add_to_queue is not implemented on this backend"
    end

    # The bug that started this: `def retry = ... if ...` was evaluated when the
    # class body loaded, so the method never existed and every Retry raised
    # NoMethodError on a healthy install.
    def test_a_dead_job_can_actually_be_retried
      failed_job(klass: "RetryMeJob")
      entry = RoundhouseUi.backend.dead_set.first
      refute_nil entry
      assert entry.respond_to?(:retry), "Entry#retry was never defined"

      assert_difference -> { ::SolidQueue::FailedExecution.count }, -1 do
        entry.retry
      end
      assert_equal 1, ::SolidQueue::ReadyExecution.where(job_id: entry.jid).count,
        "retry must put the job back on its queue"
    end

    def test_dashboard_renders_from_solid_queue
      get "/roundhouse"
      assert_response :success
      assert_match "Healthy", @response.body # composite health computed from SQ data
    end

    def test_nav_hides_sections_solid_queue_lacks
      get "/roundhouse"
      assert_response :success
      refute_match "/roundhouse/retries", @response.body # no retry set
      refute_match "/roundhouse/redis",   @response.body # not Redis-backed
      refute_match "/roundhouse/workers", @response.body # workers view deferred
      assert_match "/roundhouse/dead",      @response.body
      assert_match "/roundhouse/scheduled", @response.body
    end

    def test_dead_page_lists_solid_queue_failures
      failed_job(klass: "EmailJob", queue: "mailers", error_class: "Net::SMTPError")
      get "/roundhouse/dead"
      assert_response :success
      assert_match "EmailJob", @response.body
      assert_match "Net::SMTPError", @response.body
    end

    def test_errors_page_groups_solid_queue_failures
      failed_job(klass: "EmailJob", error_class: "Net::SMTPError")
      failed_job(klass: "EmailJob", error_class: "Net::SMTPError")
      get "/roundhouse/errors"
      assert_response :success
      assert_match "EmailJob", @response.body
      assert_match "1 issue", @response.body # two identical failures collapse to one
    end
  end
end
