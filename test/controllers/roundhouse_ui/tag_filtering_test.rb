require "test_helper"

module RoundhouseUi
  # Steps 3 and 4 of ADR 0002: tags annotate error groups, and ?tag=key:value
  # filters the job sets — applied identically in browse and bulk_apply so the
  # rows an operator sees are the rows a bulk action touches.
  class TagFilteringTest < ActionDispatch::IntegrationTest
    class FakeEntry
      attr_reader :klass, :jid, :args, :item, :at, :queue, :actions
      def initialize(klass:, jid:, queue: "default")
        @klass, @jid, @queue, @args, @at = klass, jid, queue, [], Time.now + 60
        @item = { "error_class" => "Boom", "error_message" => "boom", "retry_count" => 1, "args" => [] }
        @actions = []
      end
      define_method(:retry) { @actions << :retry }
      def delete = @actions << :delete
    end

    class FakeSet
      def initialize(entries) = @entries = entries
      def size = @entries.size
      def each(&blk) = @entries.each(&blk)
      def find_job(jid) = @entries.find { |e| e.jid == jid }
    end

    OWNERS = { "GrowthJob" => :growth, "CoreJob" => :core }.freeze

    def setup
      RoundhouseUi.read_only = false
      RoundhouseUi.job_tags = ->(klass:, item:) { { squad: OWNERS[klass] } if OWNERS.key?(klass) }
      @entries = [
        FakeEntry.new(klass: "GrowthJob", jid: "g1"),
        FakeEntry.new(klass: "GrowthJob", jid: "g2"),
        FakeEntry.new(klass: "CoreJob",   jid: "c1"),
        FakeEntry.new(klass: "UntaggedJob", jid: "u1")
      ]
      @set = FakeSet.new(@entries)
    end

    def teardown
      RoundhouseUi.job_tags = nil
      RoundhouseUi.job_tags_per_job = false
      RoundhouseUi.tag_filters = nil
      RoundhouseUi.read_only = false
    end

    # --- step 4: filtering ---------------------------------------------------

    def test_tag_filter_narrows_the_listing
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries?tag=squad:growth"
        assert_response :success
        assert_match "g1", @response.body
        assert_match "g2", @response.body
        assert_no_match(/\bc1\b/, @response.body)
        assert_no_match(/\bu1\b/, @response.body)
      end
    end

    def test_no_tag_filter_lists_everything
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries"
        assert_response :success
        %w[g1 g2 c1 u1].each { |jid| assert_match jid, @response.body }
      end
    end

    def test_a_malformed_tag_param_is_ignored_rather_than_matching_nothing
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries?tag=garbage"
        assert_response :success
        assert_match "u1", @response.body, "a valueless tag param is not a filter"
      end
    end

    def test_tag_and_text_query_combine
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries?tag=squad:growth&q=g2"
        assert_response :success
        assert_match "g2", @response.body
        assert_no_match(/\bg1\b/, @response.body)
      end
    end

    # The safety property: bulk acts on exactly the filtered set, never wider.
    def test_bulk_all_respects_the_tag_filter
      stub_method(Sidekiq::RetrySet, :new, @set) do
        post "/roundhouse/retries/bulk_all", params: { op: "delete", tag: "squad:growth" }
      end
      deleted = @entries.select { |e| e.actions.include?(:delete) }.map(&:jid)
      assert_equal %w[g1 g2], deleted.sort
    end

    def test_bulk_all_with_tag_and_query_intersects
      stub_method(Sidekiq::RetrySet, :new, @set) do
        post "/roundhouse/retries/bulk_all", params: { op: "delete", tag: "squad:growth", q: "g1" }
      end
      deleted = @entries.select { |e| e.actions.include?(:delete) }.map(&:jid)
      assert_equal %w[g1], deleted
    end

    def test_an_undeclared_key_matches_nothing_when_a_vocabulary_is_declared
      RoundhouseUi.tag_filters = { squad: %w[growth core] }
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries?tag=team:growth"
        assert_response :success
        assert_no_match(/\bg1\b/, @response.body, "fail closed on an undeclared key")
      end
    end

    def test_an_undeclared_key_matches_nothing_for_bulk_too
      RoundhouseUi.tag_filters = { squad: %w[growth core] }
      stub_method(Sidekiq::RetrySet, :new, @set) do
        post "/roundhouse/retries/bulk_all", params: { op: "delete", tag: "team:growth" }
      end
      assert_empty @entries.select { |e| e.actions.any? }, "fail-closed must apply to destructive paths"
    end

    def test_the_filter_control_renders_declared_vocabulary
      RoundhouseUi.tag_filters = { squad: %w[growth core] }
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries"
        assert_response :success
        assert_match "squad: growth", @response.body
        assert_match "squad: core", @response.body
      end
    end

    def test_the_bulk_bar_appears_for_a_tag_only_filter
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries?tag=squad:growth"
        assert_response :success
        assert_match "tagged squad: growth", @response.body,
          "the confirm/description must name the tag, not just a text query"
      end
    end

    def test_the_dead_set_filters_too
      stub_method(Sidekiq::DeadSet, :new, @set) do
        get "/roundhouse/dead?tag=squad:core"
        assert_response :success
        assert_match "c1", @response.body
        assert_no_match(/\bg1\b/, @response.body)
      end
    end

    def test_the_scheduled_set_filters_too
      stub_method(Sidekiq::ScheduledSet, :new, @set) do
        get "/roundhouse/scheduled?tag=squad:core"
        assert_response :success
        assert_match "c1", @response.body
        assert_no_match(/\bg1\b/, @response.body)
      end
    end

    # --- step 3: error groups ------------------------------------------------

    def test_error_groups_are_annotated_with_the_class_tag
      stub_method(Sidekiq::RetrySet, :new, @set) do
        stub_method(Sidekiq::DeadSet, :new, FakeSet.new([])) do
          get "/roundhouse/errors"
          assert_response :success
          assert_match "squad: growth", @response.body
          assert_match "squad: core", @response.body
        end
      end
    end
  end
end
