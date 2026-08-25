require "test_helper"

module RoundhouseUi
  module Backends
    # Exercises the Solid Queue adapter against real Solid Queue AR records in the
    # in-memory test DB (schema loaded in test_helper).
    class SolidQueueBackendTest < ActiveSupport::TestCase
      def setup
        [ ::SolidQueue::FailedExecution, ::SolidQueue::ScheduledExecution,
          ::SolidQueue::ReadyExecution, ::SolidQueue::Job ].each(&:delete_all)
        @backend = SolidQueue.new
      end

      def make_job(klass: "HardJob", queue: "default", args: [ 1, "x" ], scheduled_at: nil)
        job = ::SolidQueue::Job.create!(class_name: klass, queue_name: queue,
                                        arguments: { "arguments" => args }.to_json,
                                        scheduled_at: scheduled_at)
        # Solid Queue auto-dispatches an execution on create; drop it so each
        # test sets up exactly the execution state it's asserting on.
        ::SolidQueue::ReadyExecution.where(job_id: job.id).delete_all
        ::SolidQueue::ScheduledExecution.where(job_id: job.id).delete_all
        job
      end

      # Deleting an entry has to take the job with it. destroy removes only the
      # execution, and the orphaned solid_queue_jobs row is then invisible to
      # every page and unreachable by every worker.
      def test_deleting_an_entry_leaves_no_orphaned_job_row
        job = make_job(klass: "ChargeJob")
        ::SolidQueue::FailedExecution.create!(job: job, error: { "message" => "boom" })

        @backend.dead_set.first.delete

        assert_equal 0, ::SolidQueue::FailedExecution.count
        assert_equal 0, ::SolidQueue::Job.where(id: job.id).count, "job row outlived its execution"
      end

      def test_capabilities_reflect_solid_queue
        assert @backend.supports?(:native_pause), "pause is native in Solid Queue"
        assert @backend.supports?(:dead)
        refute @backend.supports?(:retries), "Solid Queue has no retry set"
        refute @backend.supports?(:redis)
        refute @backend.supports?(:capsules)
      end

      def test_dead_set_wraps_failed_executions
        job = make_job(klass: "ChargeJob", queue: "billing")
        ::SolidQueue::FailedExecution.create!(job: job,
          error: { "exception_class" => "RuntimeError", "message" => "boom", "backtrace" => %w[a b] })

        set = @backend.dead_set
        assert_equal 1, set.size
        entry = set.first
        assert_equal "ChargeJob", entry.klass
        assert_equal "billing", entry.queue
        assert_equal [ 1, "x" ], entry.args
        assert_equal "RuntimeError", entry.item["error_class"]
        assert_equal "boom", entry.item["error_message"]
      end

      def test_find_job_by_id
        job = make_job
        ::SolidQueue::FailedExecution.create!(job: job, error: {})
        assert_equal "HardJob", @backend.dead_set.find_job(job.id.to_s).klass
        assert_nil @backend.dead_set.find_job("nope")
      end

      def test_scheduled_set_wraps_scheduled_executions
        job = make_job(klass: "ReportJob", scheduled_at: 1.hour.from_now)
        ::SolidQueue::ScheduledExecution.create!(job: job, queue_name: "default") # scheduled_at assumed from job

        set = @backend.scheduled_set
        assert_equal 1, set.size
        assert_equal "ReportJob", set.first.klass
      end

      def test_stats_synthesizes_counts
        failed_job = make_job
        ::SolidQueue::FailedExecution.create!(job: failed_job, error: {})
        ::SolidQueue::ReadyExecution.create!(job: make_job, queue_name: "default")

        s = @backend.stats
        assert_equal 1, s.failed
        assert_equal 1, s.dead_size      # dead == failed in Solid Queue
        assert_equal 1, s.enqueued
        assert_equal 0, s.retry_size     # no retry set
      end

      def test_retry_set_is_empty
        assert_equal 0, @backend.retry_set.size
      end
    end
  end
end
