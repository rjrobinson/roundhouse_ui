require "test_helper"

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
  end
end
