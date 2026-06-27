require "test_helper"

module RoundhouseUi
  class ScheduledControllerTest < ActionDispatch::IntegrationTest
    class FakeEntry
      attr_reader :klass, :jid, :args, :item, :at, :queue, :actions
      def initialize(klass:, jid:, queue: "default", args: [], at: Time.now + 3600)
        @klass, @jid, @queue, @args, @at = klass, jid, queue, args, at
        @item = {}
        @actions = []
      end
      def add_to_queue = @actions << :enqueue
      def delete = @actions << :delete
    end

    class FakeScheduledSet
      def initialize(entries) = @entries = entries
      def size = @entries.size
      def each(&blk) = @entries.each(&blk)
      def find_job(jid) = @entries.find { |e| e.jid == jid }
    end

    def setup
      RoundhouseUi.read_only = false
      @entries = [
        FakeEntry.new(klass: "DigestEmailJob", jid: "s111", queue: "mailers"),
        FakeEntry.new(klass: "TrialExpiryJob", jid: "s222", queue: "default")
      ]
      @set = FakeScheduledSet.new(@entries)
    end

    def teardown = RoundhouseUi.read_only = false

    def test_index_lists_and_searches
      stub_method(Sidekiq::ScheduledSet, :new, @set) do
        get "/roundhouse/scheduled"
        assert_response :success
        assert_match "DigestEmailJob", @response.body
        assert_match "TrialExpiryJob", @response.body

        get "/roundhouse/scheduled", params: { q: "trial" }
        assert_match "TrialExpiryJob", @response.body
        refute_match "DigestEmailJob", @response.body
      end
    end

    def test_enqueue_now_moves_job_to_queue
      stub_method(Sidekiq::ScheduledSet, :new, @set) do
        post "/roundhouse/scheduled/s111/enqueue"
      end
      assert_response :redirect
      assert_includes @entries.first.actions, :enqueue
    end

    def test_delete_removes_scheduled_job
      stub_method(Sidekiq::ScheduledSet, :new, @set) do
        post "/roundhouse/scheduled/s222/delete"
      end
      assert_response :redirect
      assert_includes @entries.last.actions, :delete
    end

    def test_read_only_blocks_mutations
      RoundhouseUi.read_only = true
      stub_method(Sidekiq::ScheduledSet, :new, @set) do
        post "/roundhouse/scheduled/s111/enqueue"
        post "/roundhouse/scheduled/s222/delete"
      end
      assert_empty @entries.first.actions
      assert_empty @entries.last.actions
    end
  end
end
