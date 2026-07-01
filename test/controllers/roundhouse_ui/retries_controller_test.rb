require "test_helper"

module RoundhouseUi
  class RetriesControllerTest < ActionDispatch::IntegrationTest
    class FakeEntry
      attr_reader :klass, :jid, :args, :item, :at, :queue, :actions
      def initialize(klass:, jid:, error:, retry_count: 0, queue: "default", args: [], at: Time.now + 60)
        @klass, @jid, @queue, @args, @at = klass, jid, queue, args, at
        @item = { "error_class" => error, "error_message" => "#{error} happened", "retry_count" => retry_count }
        @actions = []
      end
      define_method(:retry) { @actions << :retry }
      def delete = @actions << :delete
    end

    class FakeRetrySet
      def initialize(entries) = @entries = entries
      def size = @entries.size
      def each(&blk) = @entries.each(&blk)
      def find_job(jid) = @entries.find { |e| e.jid == jid }
    end

    def setup
      RoundhouseUi.read_only = false
      @entries = [
        FakeEntry.new(klass: "SyncSlackJob",      jid: "r111", error: "Slack::TooManyRequestsError", retry_count: 2),
        FakeEntry.new(klass: "ChargeCustomerJob", jid: "r222", error: "Stripe::RateLimitError", retry_count: 18)
      ]
      @set = FakeRetrySet.new(@entries)
    end

    def teardown = RoundhouseUi.read_only = false

    def test_index_lists_and_searches
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries"
        assert_response :success
        assert_match "SyncSlackJob", @response.body
        assert_match "ChargeCustomerJob", @response.body
        assert_match "#3", @response.body # retry_count 2 shown as attempt 3

        get "/roundhouse/retries", params: { q: "stripe" }
        assert_match "ChargeCustomerJob", @response.body
        refute_match "SyncSlackJob", @response.body
      end
    end

    def test_run_now_calls_retry
      stub_method(Sidekiq::RetrySet, :new, @set) do
        post "/roundhouse/retries/r111/run"
      end
      assert_response :redirect
      assert_includes @entries.first.actions, :retry
    end

    def test_delete_calls_delete
      stub_method(Sidekiq::RetrySet, :new, @set) do
        post "/roundhouse/retries/r222/delete"
      end
      assert_response :redirect
      assert_includes @entries.last.actions, :delete
    end

    def test_read_only_blocks_mutations
      RoundhouseUi.read_only = true
      stub_method(Sidekiq::RetrySet, :new, @set) do
        post "/roundhouse/retries/r111/run"
        post "/roundhouse/retries/r222/delete"
      end
      assert_empty @entries.first.actions
      assert_empty @entries.last.actions
    end

    def test_bulk_all_acts_on_every_match
      stub_method(Sidekiq::RetrySet, :new, @set) do
        post "/roundhouse/retries/bulk_all", params: { op: "retry", q: "slack" }
      end
      assert_response :redirect
      assert_includes @entries.first.actions, :retry, "the Slack job matches and is re-run"
      assert_empty @entries.last.actions, "the Stripe job doesn't match the filter"
    end

    def test_bulk_all_blocked_in_read_only
      RoundhouseUi.read_only = true
      stub_method(Sidekiq::RetrySet, :new, @set) do
        post "/roundhouse/retries/bulk_all", params: { op: "delete", q: "slack" }
      end
      assert_empty @entries.first.actions
    end
  end
end
