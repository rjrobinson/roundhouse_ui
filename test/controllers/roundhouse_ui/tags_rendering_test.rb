require "test_helper"

module RoundhouseUi
  # Step 2 of ADR 0002: tags resolved at read time and rendered as badges on the
  # job set pages and the job detail page.
  class TagsRenderingTest < ActionDispatch::IntegrationTest
    # Match rendered badge markup, not the class name — the layout's inline
    # stylesheet defines .rh-pill-tag on every page, so the bare class name is
    # always present whether or not a badge rendered.
    BADGE_MARKUP = 'class="rh-pill rh-pill-tag"'.freeze

    class FakeEntry
      attr_reader :klass, :jid, :args, :item, :at, :queue
      def initialize(klass:, jid:, queue: "default", wrapped: nil)
        @klass, @jid, @queue, @args, @at = klass, jid, queue, [], Time.now + 60
        @item = { "jid" => jid, "error_class" => "Boom", "error_message" => "boom", "retry_count" => 1, "args" => [] }
        @item["wrapped"] = wrapped if wrapped
      end
      define_method(:retry) { }
      def delete = nil
    end

    class FakeSet
      def initialize(entries) = @entries = entries
      def size = @entries.size
      def each(&blk) = @entries.each(&blk)
      def find_job(jid) = @entries.find { |e| e.jid == jid }
    end

    def setup
      @entries = [
        FakeEntry.new(klass: "SyncSlackJob", jid: "r111"),
        FakeEntry.new(klass: "ChargeCustomerJob", jid: "r222")
      ]
      @set = FakeSet.new(@entries)
    end

    def teardown
      RoundhouseUi.job_tags = nil
      RoundhouseUi.job_tags_per_job = false
      RoundhouseUi.redact_args = []
    end

    def test_no_resolver_renders_no_badges
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries"
        assert_response :success
        assert_no_match BADGE_MARKUP, @response.body
      end
    end

    def test_badges_render_on_the_retries_page
      RoundhouseUi.job_tags = ->(klass:, item:) { { squad: klass == "SyncSlackJob" ? :growth : :core } }
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries"
        assert_response :success
        assert_match "squad: growth", @response.body
        assert_match "squad: core", @response.body
      end
    end

    def test_badges_render_on_the_dead_page
      RoundhouseUi.job_tags = ->(klass:, item:) { { squad: :growth } }
      stub_method(Sidekiq::DeadSet, :new, @set) do
        get "/roundhouse/dead"
        assert_response :success
        assert_match "squad: growth", @response.body
      end
    end

    def test_badges_render_on_the_scheduled_page
      RoundhouseUi.job_tags = ->(klass:, item:) { { squad: :platform } }
      stub_method(Sidekiq::ScheduledSet, :new, @set) do
        get "/roundhouse/scheduled"
        assert_response :success
        assert_match "squad: platform", @response.body
      end
    end

    def test_badges_render_on_the_job_detail_page
      RoundhouseUi.job_tags = ->(klass:, item:) { { squad: :ops } }
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/jobs/retry/r111"
        assert_response :success
        assert_match "squad: ops", @response.body
      end
    end

    def test_a_raising_resolver_does_not_break_the_page
      RoundhouseUi.job_tags = ->(klass:, item:) { raise "host bug" }
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries"
        assert_response :success, "a broken resolver must degrade, not 500"
        assert_no_match BADGE_MARKUP, @response.body
      end
    end

    def test_redacted_tag_values_are_masked_in_the_rendered_page
      RoundhouseUi.redact_args = %w[tenant]
      RoundhouseUi.job_tags = ->(klass:, item:) { { tenant: "acme-corp" } }
      stub_method(Sidekiq::RetrySet, :new, @set) do
        get "/roundhouse/retries"
        assert_response :success
        assert_no_match "acme-corp", @response.body
        assert_match Redaction::MASK, @response.body
      end
    end

    def test_the_activejob_wrapper_is_unwrapped_when_rendering
      wrapped = FakeSet.new([
        FakeEntry.new(klass: "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper",
                      jid: "r333", wrapped: "RealInnerJob")
      ])
      seen = []
      RoundhouseUi.job_tags = ->(klass:, item:) { seen << klass; { squad: :core } }
      stub_method(Sidekiq::RetrySet, :new, wrapped) do
        get "/roundhouse/retries"
        assert_response :success
      end
      assert_equal [ "RealInnerJob" ], seen.uniq
    end

    # The cost guarantee from ADR 0002: class-derived tags resolve once per class
    # per request, not once per row.
    def test_resolution_is_memoized_per_class_within_a_request
      many = FakeSet.new(Array.new(10) { |i| FakeEntry.new(klass: "SameJob", jid: "r#{i}") })
      calls = 0
      RoundhouseUi.job_tags = ->(klass:, item:) { calls += 1; { squad: :core } }
      stub_method(Sidekiq::RetrySet, :new, many) do
        get "/roundhouse/retries"
        assert_response :success
      end
      assert_equal 1, calls, "10 rows of one class must resolve once"
    end

    def test_per_job_mode_resolves_for_every_row
      many = FakeSet.new(Array.new(5) { |i| FakeEntry.new(klass: "SameJob", jid: "r#{i}") })
      calls = 0
      RoundhouseUi.job_tags_per_job = true
      RoundhouseUi.job_tags = ->(klass:, item:) { calls += 1; { squad: :core } }
      stub_method(Sidekiq::RetrySet, :new, many) do
        get "/roundhouse/retries"
        assert_response :success
      end
      assert_equal 5, calls, "per-job mode opts into per-row resolution"
    end
  end
end
