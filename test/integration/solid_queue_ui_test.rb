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
                                      arguments: { "arguments" => [] }.to_json)
      ::SolidQueue::ReadyExecution.where(job_id: job.id).delete_all # drop auto-dispatch
      ::SolidQueue::FailedExecution.create!(job: job,
        error: { "exception_class" => error_class, "message" => "kaboom" })
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
