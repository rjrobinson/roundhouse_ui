require "test_helper"

# Stand-in for sidekiq-failures' FailureSet (a Sidekiq::JobSet subclass), which
# isn't a dependency of this gem. Defining it satisfies the
# `defined?(Sidekiq::Failures::FailureSet)` guard so the opt-in path is testable;
# it stays inert because RoundhouseUi.show_sidekiq_failures defaults to false.
module Sidekiq
  module Failures
    class FailureSet; end
  end
end

module RoundhouseUi
  class ErrorsControllerTest < ActionDispatch::IntegrationTest
    class FakeEntry
      attr_reader :klass, :item, :at, :queue
      def initialize(klass:, error_class:, at:, queue: "default")
        @klass, @at, @queue = klass, at, queue
        @item = { "error_class" => error_class }
      end
    end

    class FakeSet
      def initialize(entries) = @entries = entries
      def each(&blk) = @entries.each(&blk)
    end

    def stub_sets(retry_entries:, dead_entries:)
      stub_method(Sidekiq::RetrySet, :new, FakeSet.new(retry_entries)) do
        stub_method(Sidekiq::DeadSet, :new, FakeSet.new(dead_entries)) do
          yield
        end
      end
    end

    def test_groups_identical_failures_into_one_issue
      now = Time.now
      stub_sets(
        retry_entries: [
          FakeEntry.new(klass: "BulkImportJob", error_class: "PG::TooManyConnections", at: now, queue: "low"),
          FakeEntry.new(klass: "BulkImportJob", error_class: "PG::TooManyConnections", at: now - 60, queue: "low")
        ],
        dead_entries: [
          FakeEntry.new(klass: "ChargeCustomerJob", error_class: "Stripe::RateLimitError", at: now, queue: "default")
        ]
      ) do
        get "/roundhouse/errors"

        assert_response :success
        assert_match "2 issues", @response.body                 # collapsed, not 3 rows
        assert_match "BulkImportJob", @response.body
        assert_match "PG::TooManyConnections", @response.body
        assert_match "ChargeCustomerJob", @response.body
      end
    end

    def test_search_filters_groups
      now = Time.now
      stub_sets(
        retry_entries: [ FakeEntry.new(klass: "BulkImportJob", error_class: "PG::TooManyConnections", at: now) ],
        dead_entries:  [ FakeEntry.new(klass: "ChargeCustomerJob", error_class: "Stripe::RateLimitError", at: now) ]
      ) do
        get "/roundhouse/errors", params: { q: "stripe" }

        assert_response :success
        assert_match "ChargeCustomerJob", @response.body
        refute_match "BulkImportJob", @response.body
      end
    end

    def with_show_sidekiq_failures(value)
      original = RoundhouseUi.show_sidekiq_failures
      RoundhouseUi.show_sidekiq_failures = value
      yield
    ensure
      RoundhouseUi.show_sidekiq_failures = original
    end

    def stub_all_sets(retry_entries:, dead_entries:, failed_entries:)
      stub_method(Sidekiq::RetrySet, :new, FakeSet.new(retry_entries)) do
        stub_method(Sidekiq::DeadSet, :new, FakeSet.new(dead_entries)) do
          stub_method(Sidekiq::Failures::FailureSet, :new, FakeSet.new(failed_entries)) do
            yield
          end
        end
      end
    end

    def test_includes_sidekiq_failures_when_opted_in
      now = Time.now
      with_show_sidekiq_failures(true) do
        stub_all_sets(
          retry_entries: [],
          dead_entries: [],
          failed_entries: [ FakeEntry.new(klass: "EmailJob", error_class: "Net::SMTPError", at: now, queue: "mailers") ]
        ) do
          get "/roundhouse/errors"

          assert_response :success
          assert_match "EmailJob", @response.body
          assert_match "Net::SMTPError", @response.body
        end
      end
    end

    def test_rows_link_to_datadog_when_an_adapter_is_configured
      original = RoundhouseUi.observability
      RoundhouseUi.observability = RoundhouseUi::Observability::DatadogAdapter.new(service: "sidekiq")
      stub_sets(
        retry_entries: [ FakeEntry.new(klass: "BulkImportJob", error_class: "PG::Error", at: Time.now) ],
        dead_entries: []
      ) do
        get "/roundhouse/errors"

        assert_response :success
        assert_match "Open in Datadog", @response.body # icon-only link, name in the title
        assert_match "app.datadoghq.com/apm/traces", @response.body
      end
    ensure
      RoundhouseUi.observability = original
    end

    def test_ignores_sidekiq_failures_when_not_opted_in
      now = Time.now
      # Flag off (the default) — the failed set must not be read even when it
      # holds failures and the gem is present.
      stub_all_sets(
        retry_entries: [],
        dead_entries: [],
        failed_entries: [ FakeEntry.new(klass: "EmailJob", error_class: "Net::SMTPError", at: now) ]
      ) do
        get "/roundhouse/errors"

        assert_response :success
        refute_match "EmailJob", @response.body
      end
    end

    def test_a_single_issue_reads_as_one_issue
      stub_sets(
        retry_entries: [ FakeEntry.new(klass: "W", error_class: "Boom", at: Time.now) ],
        dead_entries: []
      ) do
        get "/roundhouse/errors"

        markup = @response.body.split("</style>").last.to_s
        assert_match(/1 issue\b/, markup)
        refute_match(/1 issues/, markup, "a count has to agree with its noun")
      end
    end

    def test_a_truncated_scan_marks_its_counts_as_floors
      # Past the scan limit the count is a lower bound, not a total. Printing an
      # exact figure for a number we know is capped is the one thing the footnote
      # below the table cannot fix.
      now = Time.now
      over = ErrorGroups::DEFAULT_SCAN_LIMIT + 1
      stub_sets(
        retry_entries: Array.new(over) { FakeEntry.new(klass: "W", error_class: "Boom", at: now) },
        dead_entries: []
      ) do
        get "/roundhouse/errors"

        markup = @response.body.split("</style>").last.to_s
        assert_match "older entries not yet scanned", markup, "expected a truncated scan"
        assert_match(/>1,000\+</, markup, "a capped count is printed as though it were exact")
      end
    end

    def test_an_untruncated_count_carries_no_plus
      stub_sets(
        retry_entries: [ FakeEntry.new(klass: "W", error_class: "Boom", at: Time.now) ],
        dead_entries: []
      ) do
        get "/roundhouse/errors"

        markup = @response.body.split("</style>").last.to_s
        refute_match(/>1\+</, markup, "nothing was capped, so nothing should claim to be")
      end
    end
  end
end
