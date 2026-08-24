require "test_helper"

module RoundhouseUi
  # Runbooks (#39): whoever wrote the job knows what to do when it fails, and the
  # person paged at 3am usually does not. Resolved at read time like tags, so it
  # applies to jobs already in the sets.
  class RunbooksTest < ActiveSupport::TestCase
    def teardown = RoundhouseUi.job_runbooks = nil

    def test_nothing_configured_resolves_to_nothing
      assert_nil Runbooks.for("Anything")
    end

    def test_a_hash_keyed_by_class_name
      RoundhouseUi.job_runbooks = { "Billing::SyncWorker" => "https://wiki.test/billing" }
      assert_equal "https://wiki.test/billing", Runbooks.for("Billing::SyncWorker")
      assert_nil Runbooks.for("Other::Worker")
    end

    def test_any_callable_works
      RoundhouseUi.job_runbooks = ->(klass:, item:) { "https://wiki.test/#{klass}" }
      assert_equal "https://wiki.test/W", Runbooks.for("W")
    end

    # A runbook declared on a mailer has to be found when that mailer fails —
    # which it only is if the ActiveJob wrapper is unwrapped first.
    def test_activejob_wrapped_jobs_resolve_by_their_real_class
      RoundhouseUi.job_runbooks = { "ActionMailer::MailDeliveryJob" => "https://wiki.test/mail" }
      item = { "class" => "Sidekiq::ActiveJob::Wrapper", "wrapped" => "ActionMailer::MailDeliveryJob" }
      assert_equal "https://wiki.test/mail", Runbooks.for(item["class"], item)
    end

    def test_the_constant_convention_matches_the_tags_one
      RoundhouseUi.job_runbooks = Runbooks.from_constant(:RUNBOOK)
      assert_equal "https://wiki.test/alpha", Runbooks.for("RunbookFixtures::Alpha")
      assert_nil Runbooks.for("RunbookFixtures::Bare")
    end

    # Inherited constants count, so one base class can carry a whole family.
    def test_a_base_class_runbook_covers_its_subclasses
      RoundhouseUi.job_runbooks = Runbooks.from_constant(:RUNBOOK)
      assert_equal "https://wiki.test/alpha", Runbooks.for("RunbookFixtures::Child")
    end

    # This lands in an href. There is no escaping that makes a javascript: URL
    # safe there, so the scheme is checked rather than the content escaped —
    # a misconfigured host gets no link, not a link that runs.
    def test_only_http_urls_are_returned
      [ "javascript:alert(1)", "data:text/html,<script>", "file:///etc/passwd",
        "  ", "", "not a url", "//evil.test/x" ].each do |bad|
        RoundhouseUi.job_runbooks = { "W" => bad }
        assert_nil Runbooks.for("W"), "should refuse #{bad.inspect}"
      end
    end

    def test_https_and_http_both_pass
      RoundhouseUi.job_runbooks = { "W" => "http://wiki.test/x" }
      assert_equal "http://wiki.test/x", Runbooks.for("W")
    end

    # A runbook lookup must never be the reason a page 500s.
    def test_a_raising_resolver_degrades_to_no_runbook
      RoundhouseUi.job_runbooks = ->(klass:, item:) { raise "boom" }
      assert_nil Runbooks.for("W")
    end

    def test_resolution_is_cached_per_class
      calls = 0
      RoundhouseUi.job_runbooks = ->(klass:, item:) { calls += 1; "https://wiki.test/x" }
      cache = {}
      3.times { Runbooks.for("W", nil, cache: cache) }
      assert_equal 1, calls, "the same class must not be resolved twice in one request"
    end
  end

  class RunbookRenderingTest < ActionDispatch::IntegrationTest
    class FakeEntry
      attr_reader :klass, :item, :at, :queue
      def initialize(klass:, error_class:, queue: "default")
        @klass, @queue, @at = klass, queue, Time.now
        @item = { "error_class" => error_class }
      end
    end

    class FakeSet
      def initialize(entries) = @entries = entries
      def each(&blk) = @entries.each(&blk)
    end

    def with_failures
      entries = [ FakeEntry.new(klass: "Billing::SyncWorker", error_class: "Net::ReadTimeout") ]
      stub_method(Sidekiq::RetrySet, :new, FakeSet.new(entries)) do
        stub_method(Sidekiq::DeadSet, :new, FakeSet.new([])) { yield }
      end
    end

    def teardown = RoundhouseUi.job_runbooks = nil

    # The needle is the rendered anchor, not the class name: `.rh-runbook` is
    # also a CSS rule in the layout, so every page contains that string whether
    # a link rendered or not.
    def test_no_runbook_renders_no_link
      with_failures do
        get "/roundhouse/errors"
        assert_response :success
        refute_match 'class="rh-runbook"', @response.body
      end
    end

    def test_a_configured_runbook_reaches_the_error_group
      RoundhouseUi.job_runbooks = { "Billing::SyncWorker" => "https://wiki.test/billing" }
      with_failures do
        get "/roundhouse/errors"
        assert_response :success
        assert_match 'class="rh-runbook"', @response.body
        assert_match "https://wiki.test/billing", @response.body
      end
    end

    # It opens someone else's site in a new tab, so it must not hand that page a
    # window.opener reference back to the console.
    def test_the_link_opens_safely
      RoundhouseUi.job_runbooks = { "Billing::SyncWorker" => "https://wiki.test/billing" }
      with_failures do
        get "/roundhouse/errors"
        assert_match 'rel="noopener noreferrer"', @response.body
        assert_match 'target="_blank"', @response.body
      end
    end

    def test_a_class_without_a_runbook_gets_no_link
      RoundhouseUi.job_runbooks = { "Something::Else" => "https://wiki.test/x" }
      with_failures do
        get "/roundhouse/errors"
        refute_match 'class="rh-runbook"', @response.body
      end
    end
  end
end

module RunbookFixtures
  class Alpha
    RUNBOOK = "https://wiki.test/alpha".freeze
  end
  class Child < Alpha; end
  class Bare; end
end
