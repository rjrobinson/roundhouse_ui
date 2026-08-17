require "test_helper"

module RoundhouseUi
  # ErrorGroups had no unit coverage of its own — only incidental coverage
  # through controller tests whose fixtures carried no ActiveJob wrapper, which
  # is why every ActiveJob failure collapsing into one row went unnoticed (#30).
  class ErrorGroupsTest < ActiveSupport::TestCase
    WRAPPER = "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper".freeze

    class FakeEntry
      attr_reader :klass, :jid, :queue, :at, :item
      def initialize(klass:, error: "Boom", wrapped: nil, queue: "default", jid: "j1")
        @klass, @queue, @jid, @at = klass, queue, jid, Time.now
        @item = { "jid" => jid, "error_class" => error }
        @item["wrapped"] = wrapped if wrapped
      end
    end

    class FakeSet
      include Enumerable
      def initialize(entries) = @entries = entries
      def each(&blk) = @entries.each(&blk)
    end

    def with_sets(retry_entries: [], dead_entries: [])
      stub_method(Sidekiq::RetrySet, :new, FakeSet.new(retry_entries)) do
        stub_method(Sidekiq::DeadSet, :new, FakeSet.new(dead_entries)) { yield }
      end
    end

    def teardown = RoundhouseUi.job_tags = nil

    # The defect: two unrelated jobs, one wrapper class, one meaningless row.
    def test_wrapped_jobs_group_by_their_real_class
      entries = [
        FakeEntry.new(klass: WRAPPER, wrapped: "ActionMailer::MailDeliveryJob", jid: "a"),
        FakeEntry.new(klass: WRAPPER, wrapped: "Noticed::DeliveryMethods::Email", jid: "b")
      ]
      groups = with_sets(dead_entries: entries) { ErrorGroups.new.call.groups }

      assert_equal 2, groups.size, "one wrapper class must not collapse two real jobs into one row"
      assert_equal [ "ActionMailer::MailDeliveryJob", "Noticed::DeliveryMethods::Email" ],
        groups.map { |g| g[:klass] }.sort
      refute_includes groups.map { |g| g[:klass] }, WRAPPER
    end

    def test_plain_workers_group_exactly_as_before
      entries = [
        FakeEntry.new(klass: "SyncWorker", error: "Timeout::Error", jid: "a"),
        FakeEntry.new(klass: "SyncWorker", error: "Timeout::Error", jid: "b"),
        FakeEntry.new(klass: "SyncWorker", error: "PG::Error",      jid: "c")
      ]
      groups = with_sets(dead_entries: entries) { ErrorGroups.new.call.groups }

      assert_equal 2, groups.size, "still fingerprinted on class + error"
      assert_equal 2, groups.find { |g| g[:error] == "Timeout::Error" }[:count]
    end

    # The unwrap has to be the identity the fingerprint uses, not a display
    # nicety layered on top — otherwise the same job counted twice under two
    # names depending on how it was enqueued.
    def test_a_wrapped_and_an_unwrapped_instance_of_one_class_share_a_group
      entries = [
        FakeEntry.new(klass: WRAPPER, wrapped: "ReportJob", jid: "a"),
        FakeEntry.new(klass: "ReportJob", jid: "b")
      ]
      groups = with_sets(dead_entries: entries) { ErrorGroups.new.call.groups }

      assert_equal 1, groups.size
      assert_equal "ReportJob", groups.first[:klass]
      assert_equal 2, groups.first[:count]
    end

    # Search greps the same value the dashboard puts in errors_path(q:), so the
    # two have to agree or that link goes nowhere.
    def test_search_matches_the_unwrapped_class
      entries = [ FakeEntry.new(klass: WRAPPER, wrapped: "ReportJob") ]

      found = with_sets(dead_entries: entries) { ErrorGroups.new(query: "ReportJob").call.groups }
      assert_equal 1, found.size

      gone = with_sets(dead_entries: entries) { ErrorGroups.new(query: "JobWrapper").call.groups }
      assert_empty gone, "the wrapper name is no longer the job's identity"
    end

    # Before this, every ActiveJob group resolved tags against the wrapper,
    # found no OWNER, and rendered an empty squad cell.
    def test_tags_resolve_for_a_wrapped_group
      RoundhouseUi.job_tags = ->(klass:, item:) { { squad: "growth" } if klass == "ReportJob" }
      entries = [ FakeEntry.new(klass: WRAPPER, wrapped: "ReportJob") ]
      groups = with_sets(dead_entries: entries) { ErrorGroups.new.call.groups }

      assert_equal({ "squad" => "growth" }, Tags.for(klass: groups.first[:klass], item: {}))
    end
  end
end
