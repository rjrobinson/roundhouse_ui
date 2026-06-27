require "test_helper"

module RoundhouseUi
  class DeadControllerTest < ActionDispatch::IntegrationTest
    # Minimal stand-ins for Sidekiq::SortedEntry / Sidekiq::DeadSet so the test
    # needs no running Redis. (`retry` is a keyword, so define it dynamically.)
    class FakeEntry
      attr_reader :klass, :jid, :args, :item, :at, :queue, :actions
      def initialize(klass:, jid:, error:, queue: "default", args: [], at: Time.now)
        @klass, @jid, @queue, @args, @at = klass, jid, queue, args, at
        # Real Sidekiq stores the class in error_class and the text in error_message.
        @item = { "error_class" => error, "error_message" => "#{error} happened" }
        @actions = []
      end
      define_method(:retry) { @actions << :retry }
      def delete = @actions << :delete
    end

    class FakeDeadSet
      def initialize(entries) = @entries = entries
      def size = @entries.size
      def each(&blk) = @entries.each(&blk)
      def find_job(jid) = @entries.find { |e| e.jid == jid }
    end

    def setup
      RoundhouseUi.read_only = false
      @entries = [
        FakeEntry.new(klass: "BulkImportJob",     jid: "aaa111", error: "PG::TooManyConnections"),
        FakeEntry.new(klass: "ChargeCustomerJob", jid: "bbb222", error: "Stripe::RateLimitError")
      ]
      @set = FakeDeadSet.new(@entries)
    end

    def teardown
      RoundhouseUi.read_only = false
      RoundhouseUi.observability = RoundhouseUi::Observability::NullAdapter.new
    end

    def test_index_lists_and_searches
      stub_method(Sidekiq::DeadSet, :new, @set) do
        get "/roundhouse/dead"
        assert_response :success
        assert_match "BulkImportJob", @response.body
        assert_match "ChargeCustomerJob", @response.body

        get "/roundhouse/dead", params: { q: "stripe" }
        assert_response :success
        assert_match "ChargeCustomerJob", @response.body
        refute_match "BulkImportJob", @response.body
      end
    end

    def test_pagination_windows_results
      entries = (1..30).map { |i| FakeEntry.new(klass: "DemoJob", jid: format("j%02d", i), error: "E") }
      stub_method(Sidekiq::DeadSet, :new, FakeDeadSet.new(entries)) do
        get "/roundhouse/dead?page=1"
        assert_match "j01", @response.body
        assert_match "j25", @response.body
        refute_match "j26", @response.body
        assert_match "Next", @response.body

        get "/roundhouse/dead?page=2"
        assert_match "j26", @response.body
        assert_match "j30", @response.body
        refute_match "j01", @response.body
        assert_match "Prev", @response.body
      end
    end

    def test_trace_link_renders_when_observability_configured
      RoundhouseUi.observability = RoundhouseUi::Observability::DatadogAdapter.new(service: "trainual")
      stub_method(Sidekiq::DeadSet, :new, @set) do
        get "/roundhouse/dead"
        assert_match "Datadog", @response.body
        assert_match "app.datadoghq.com/apm/traces", @response.body
      end
    end

    def test_no_trace_link_by_default
      stub_method(Sidekiq::DeadSet, :new, @set) do
        get "/roundhouse/dead"
        refute_match "datadoghq.com", @response.body
      end
    end

    def test_requeue_calls_retry_on_the_entry
      stub_method(Sidekiq::DeadSet, :new, @set) do
        post "/roundhouse/dead/aaa111/retry"
      end
      assert_response :redirect
      assert_includes @entries.first.actions, :retry
    end

    def test_destroy_calls_delete_on_the_entry
      stub_method(Sidekiq::DeadSet, :new, @set) do
        post "/roundhouse/dead/bbb222/delete"
      end
      assert_response :redirect
      assert_includes @entries.last.actions, :delete
    end

    def test_bulk_retry_acts_on_all_selected
      stub_method(Sidekiq::DeadSet, :new, @set) do
        post "/roundhouse/dead/bulk", params: { op: "retry", jids: %w[aaa111 bbb222] }
      end
      assert_response :redirect
      assert_includes @entries.first.actions, :retry
      assert_includes @entries.last.actions, :retry
    end

    def test_bulk_delete_acts_on_selected_only
      stub_method(Sidekiq::DeadSet, :new, @set) do
        post "/roundhouse/dead/bulk", params: { op: "delete", jids: %w[aaa111] }
      end
      assert_response :redirect
      assert_includes @entries.first.actions, :delete
      assert_empty @entries.last.actions
    end

    def test_bulk_blocked_in_read_only
      RoundhouseUi.read_only = true
      stub_method(Sidekiq::DeadSet, :new, @set) do
        post "/roundhouse/dead/bulk", params: { op: "retry", jids: %w[aaa111 bbb222] }
      end
      assert_empty @entries.first.actions
      assert_empty @entries.last.actions
    end

    def test_read_only_mode_blocks_mutations
      RoundhouseUi.read_only = true
      stub_method(Sidekiq::DeadSet, :new, @set) do
        post "/roundhouse/dead/aaa111/retry"
        post "/roundhouse/dead/bbb222/delete"
      end
      assert_empty @entries.first.actions
      assert_empty @entries.last.actions
    end
  end
end
