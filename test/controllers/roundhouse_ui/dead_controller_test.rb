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
      RoundhouseUi.job_tags = nil
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
      RoundhouseUi.observability = RoundhouseUi::Observability::DatadogAdapter.new(service: "sidekiq")
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

    def test_bulk_all_acts_on_every_match_not_just_selected
      stub_method(Sidekiq::DeadSet, :new, @set) do
        post "/roundhouse/dead/bulk_all", params: { op: "retry", q: "stripe" }
      end
      assert_response :redirect
      assert_empty @entries.first.actions, "BulkImportJob doesn't match the filter"
      assert_includes @entries.last.actions, :retry, "the Stripe job matches and is retried"
    end

    def test_bulk_all_blocked_in_read_only
      RoundhouseUi.read_only = true
      stub_method(Sidekiq::DeadSet, :new, @set) do
        post "/roundhouse/dead/bulk_all", params: { op: "delete", q: "stripe" }
      end
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

    # Dry run (#37). Bulk actions run on a filter rather than a page, so the
    # count tells you how many and never which. These pin that the preview shows
    # the real set and changes nothing.
    def test_preview_lists_the_jobs_a_bulk_action_would_touch
      stub_method(Sidekiq::DeadSet, :new, @set) do
        get "/roundhouse/dead/preview", params: { op: "delete", q: "Stripe" }

        assert_response :success
        assert_match "ChargeCustomerJob", @response.body
        refute_match "BulkImportJob", @response.body, "a non-matching job must not be listed"
        assert_match "Delete 1", @response.body
      end
    end

    # The whole promise of a dry run.
    def test_preview_touches_nothing
      stub_method(Sidekiq::DeadSet, :new, @set) do
        get "/roundhouse/dead/preview", params: { op: "delete", q: "Stripe" }
        assert_response :success
      end
      assert_empty @entries.flat_map(&:actions), "preview must not act on any job"
    end

    # A destructive-scope bug already happened here once: a form that dropped the
    # queue filter would delete more than the page showed.
    # This test used to enumerate four filters by hand while its name promised
    # every one. So when class= and error= were added, it kept passing while the
    # confirm form silently dropped both — and a dry run listing two jobs POSTed a
    # request that deleted five. The test and the six hand-enumerating call sites
    # had the same bug: a hardcoded list nobody updates.
    #
    # The filter is one parameter now, so "carried four of the five" is not a shape
    # this form can take. What is asserted instead is the property the old test was
    # a proxy for, and it is stronger: the q the POST will filter on reconstructs
    # the IDENTICAL FilterQuery the dry run browsed with. Not a key list — the
    # actual value, compared as a parsed query.
    #
    # Sent in the legacy five-param shape on purpose: that is what a bookmark or an
    # older link looks like, so this covers the compatibility read at the same time.
    def test_the_confirm_form_carries_every_filter
      # A live tag resolver, so the tag filter actually selects rather than
      # excluding everything and leaving nothing to assert against.
      RoundhouseUi.job_tags = ->(klass:, item:) { { squad: "core" } }
      # Values that MATCH the fixture. With values that match nothing the preview
      # renders "Nothing to do" and no form, and the test would pass on absence.
      sent = { op: "delete", q: "Stripe", queue: "default", tag: "squad:core",
               class: "ChargeCustomerJob", error: "Stripe::RateLimitError" }
      expected = FilterQuery.from_params(sent)
      refute expected.invalid?, "the fixture filter must itself be representable"

      stub_method(Sidekiq::DeadSet, :new, @set) do
        get "/roundhouse/dead/preview", params: sent

        assert_select "form[action=?]", "/roundhouse/dead/bulk_all"

        carried = css_select("form[action='/roundhouse/dead/bulk_all'] input")
                  .to_h { |i| [ i["name"], i["value"] ] }
        assert_equal "delete", carried["op"]

        assert_equal expected, FilterQuery.parse(carried["q"]),
          "the confirm form posts #{carried['q'].inspect}, but the dry run above it " \
          "listed jobs matching #{expected.to_s.inspect}. Whatever the POST does not " \
          "carry it will not filter on, so the set you approved and the set that gets " \
          "destroyed are different. It carried: #{carried.keys.inspect}"
        # Every facet must actually be IN that one value — an empty q would compare
        # equal to an empty expectation and this test would pass on nothing at all.
        assert_equal %w[class error queue tag], expected.chips.map { |k, _| k.to_s }.sort
      end
    end


    def test_preview_says_so_when_nothing_matches
      stub_method(Sidekiq::DeadSet, :new, @set) do
        get "/roundhouse/dead/preview", params: { op: "delete", q: "matches-nothing" }

        assert_response :success
        assert_match "Nothing to do", @response.body
        assert_select "form[action=?]", "/roundhouse/dead/bulk_all", count: 0,
          message: "there must be nothing to confirm when nothing matches"
      end
    end

    # An unrecognised op must not silently become a delete.
    def test_an_unknown_op_falls_back_to_retry
      stub_method(Sidekiq::DeadSet, :new, @set) do
        get "/roundhouse/dead/preview", params: { op: "obliterate", q: "Stripe" }

        assert_response :success
        assert_match "Retry 1", @response.body
        refute_match "Delete 1", @response.body
      end
    end

    def test_read_only_refuses_the_preview
      RoundhouseUi.read_only = true
      stub_method(Sidekiq::DeadSet, :new, @set) do
        get "/roundhouse/dead/preview", params: { op: "delete", q: "Stripe" }
        assert_redirected_to "/roundhouse/dead"
      end
    end
  end
end
