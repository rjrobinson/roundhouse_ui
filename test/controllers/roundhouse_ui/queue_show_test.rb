require "test_helper"

module RoundhouseUi
  # Clicking into a queue to see what is waiting on it — the thing Sidekiq Web
  # has and Roundhouse did not.
  class QueueShowTest < ActionDispatch::IntegrationTest
    class FakeJob
      attr_reader :klass, :jid, :args, :item, :queue, :at
      def initialize(klass:, jid:, args: [], queue: "mailers", wrapped: nil, age: 30)
        @klass, @jid, @args, @queue, @at = klass, jid, args, queue, nil
        @item = { "class" => klass, "jid" => jid, "args" => args,
                  "enqueued_at" => Time.now.to_f - age }
        @item["wrapped"] = wrapped if wrapped
      end
    end

    class FakeQueue
      include Enumerable
      def initialize(jobs) = @jobs = jobs
      def each(&blk) = @jobs.each(&blk)
    end

    def seed_summary(fake, name, size)
      fake.call("SADD", "queues", name)
      size.times { |i| fake.call("LPUSH", "queue:#{name}", Sidekiq.dump_json("jid" => "s#{i}", "enqueued_at" => Time.now.to_f - 30)) }
    end

    def teardown = RoundhouseUi.job_tags = nil

    def with_queue(jobs, name: "mailers")
      with_fake_redis do |fake|
        seed_summary(fake, name, jobs.size)
        stub_method(Sidekiq::Queue, :new, FakeQueue.new(jobs)) { yield }
      end
    end

    def test_lists_the_jobs_waiting_on_the_queue
      jobs = [ FakeJob.new(klass: "SyncWorker", jid: "a1", args: [ 42 ]),
               FakeJob.new(klass: "MailWorker", jid: "b2", args: [ { "account_id" => 7 } ]) ]
      with_queue(jobs) do
        get "/roundhouse/queues/mailers"
        assert_response :success
        assert_match "SyncWorker", @response.body
        assert_match "MailWorker", @response.body
        assert_match "a1", @response.body
        assert_match "2 waiting", @response.body
      end
    end

    # The reason this page exists: a queue full of one class is indistinguishable
    # row to row without them.
    def test_shows_job_arguments
      with_queue([ FakeJob.new(klass: "SyncWorker", jid: "a1", args: [ { "account_id" => 91823 } ]) ]) do
        get "/roundhouse/queues/mailers"
        assert_response :success
        assert_match "91823", @response.body
      end
    end

    def test_redacts_sensitive_arguments
      RoundhouseUi.redact_args = %w[token]
      with_queue([ FakeJob.new(klass: "SyncWorker", jid: "a1", args: [ { "token" => "sk_live_secret" } ]) ]) do
        get "/roundhouse/queues/mailers"
        assert_response :success
        assert_no_match "sk_live_secret", @response.body
        assert_match Redaction::MASK, @response.body
      end
    ensure
      RoundhouseUi.redact_args = []
    end

    def test_searches_within_the_queue
      jobs = [ FakeJob.new(klass: "SyncWorker", jid: "a1"), FakeJob.new(klass: "MailWorker", jid: "b2") ]
      with_queue(jobs) do
        get "/roundhouse/queues/mailers?q=Sync"
        assert_response :success
        assert_match "SyncWorker", @response.body
        assert_no_match "MailWorker", @response.body
      end
    end

    def test_shows_the_real_class_for_an_activejob_wrapped_job
      wrapped = FakeJob.new(klass: "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper",
                            jid: "w1", wrapped: "ActionMailer::MailDeliveryJob")
      with_queue([ wrapped ]) do
        get "/roundhouse/queues/mailers"
        assert_response :success
        assert_match "ActionMailer::MailDeliveryJob", @response.body
        assert_no_match "JobWrapper", @response.body
      end
    end

    def test_an_empty_queue_says_so_without_claiming_a_filter_matched_nothing
      with_queue([]) do
        get "/roundhouse/queues/mailers"
        assert_response :success
        assert_match "Nothing waiting on", @response.body
      end
    end

    # The GET route sits alongside POST purge/pause/resume/snapshot on the same
    # path prefix; it must not shadow them.
    def test_the_show_route_does_not_shadow_the_queue_actions
      cleared = []
      fake = Object.new.tap { |o| o.define_singleton_method(:clear) { cleared << true } }
      stub_method(Sidekiq::Queue, :new, fake) { post "/roundhouse/queues/mailers/purge" }
      assert_response :redirect
      assert_equal [ true ], cleared
    end
  end
end
