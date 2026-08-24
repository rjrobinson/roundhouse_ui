require "test_helper"

module RoundhouseUi
  # Job class names arrive in the payload — `item["class"]` / `item["wrapped"]`
  # — which is data, not code. String#safe_constantize resolves any real
  # constant, so what reaches it is narrowed first.
  class JobClassTest < ActiveSupport::TestCase
    def test_resolves_a_real_job_class
      assert_equal RoundhouseUi::Theme, RoundhouseUi.job_class("RoundhouseUi::Theme")
    end

    def test_unknown_but_well_formed_names_resolve_to_nothing
      assert_nil RoundhouseUi.job_class("No::Such::Worker")
    end

    # These never reach the constant lookup at all.
    def test_malformed_names_are_rejected_before_constant_lookup
      [ "", "  ", "lowercase", "9Leading", "Has-Dash", "Has Space", "Has::lower",
        "Trailing::", "::Leading", "Semi;colon", "../../etc/passwd",
        "Foo::Bar!", "Foo\nBar", "A" * 201 ].each do |bad|
        assert_nil RoundhouseUi.job_class(bad), "should reject #{bad.inspect}"
      end
    end

    def test_absurdly_long_names_are_rejected
      assert_nil RoundhouseUi.job_class("A::" * 500 + "B")
    end

    def test_nil_and_non_strings_are_safe
      assert_nil RoundhouseUi.job_class(nil)
      assert_nil RoundhouseUi.job_class(42)
      assert_nil RoundhouseUi.job_class([ "Kernel" ])
    end

    # A name resolving to something that is not a Module would be sent
    # const_defined?, which it does not answer.
    def test_only_modules_come_back
      assert_nil RoundhouseUi.job_class("RoundhouseUi::Theme::TOKENS"),
        "a constant holding an Array is not a job class"
      assert_equal Kernel, RoundhouseUi.job_class("Kernel")
    end

    # Deeply nested real-world names must still work — this rule sits in front of
    # every tag and runbook lookup, so a false negative silently drops a feature.
    def test_real_world_shapes_all_pass
      %w[W Worker AlphaJob V2::Worker Billing::SyncWorker
         Ai::Documents::SummarizeWorker Some_Worker Api2::V3::Job_9
         ActionMailer::MailDeliveryJob Sidekiq::ActiveJob::Wrapper].each do |name|
        assert_match RoundhouseUi::JOB_CLASS_NAME, name, "#{name} must be accepted"
      end
    end

    # The namespace allowlist is the only control here that actually restricts
    # what may be loaded — it runs before the constant lookup. The shape checks
    # do not: Ruby rejects a malformed path before attempting any lookup, so
    # those names were never able to autoload anything.
    def test_the_allowlist_denies_constants_outside_it
      RoundhouseUi.job_class_namespaces = %w[RoundhouseUi]
      assert_equal RoundhouseUi::Theme, RoundhouseUi.job_class("RoundhouseUi::Theme")
      assert_nil RoundhouseUi.job_class("Kernel"), "a real constant outside the allowlist must not resolve"
      assert_nil RoundhouseUi.job_class("File")
    ensure
      RoundhouseUi.job_class_namespaces = nil
    end

    # "RoundhouseUiEvil" starts with an allowed name but is not inside it.
    def test_the_allowlist_is_not_fooled_by_a_shared_prefix
      RoundhouseUi.job_class_namespaces = %w[RoundhouseUi]
      assert_nil RoundhouseUi.job_class("RoundhouseUiEvil")
    ensure
      RoundhouseUi.job_class_namespaces = nil
    end

    def test_an_exact_namespace_match_resolves
      RoundhouseUi.job_class_namespaces = %w[Kernel]
      assert_equal Kernel, RoundhouseUi.job_class("Kernel")
    ensure
      RoundhouseUi.job_class_namespaces = nil
    end

    # Unset means unrestricted — this must not silently become opt-out.
    def test_no_allowlist_means_no_restriction
      assert_nil RoundhouseUi.job_class_namespaces
      assert_equal Kernel, RoundhouseUi.job_class("Kernel")
      RoundhouseUi.job_class_namespaces = []
      assert_equal Kernel, RoundhouseUi.job_class("Kernel"), "an empty list is not a deny-all"
    ensure
      RoundhouseUi.job_class_namespaces = nil
    end

    # It has to reach the resolvers, or it is a setting that does nothing.
    def test_the_allowlist_reaches_tag_resolution
      RoundhouseUi.job_tags = Tags.from_constant(:OWNER, as: :squad)
      RoundhouseUi.job_class_namespaces = %w[Nothing]
      assert_equal Tags::EMPTY, Tags.for(klass: "JobClassFixtures::Owned", item: {})
      RoundhouseUi.job_class_namespaces = %w[JobClassFixtures]
      assert_equal({ "squad" => "payments" }, Tags.for(klass: "JobClassFixtures::Owned", item: {}))
    ensure
      RoundhouseUi.job_tags = nil
      RoundhouseUi.job_class_namespaces = nil
    end

    # The whole point: resolvers see the narrowed result.
    def test_tag_resolvers_do_not_constantize_hostile_names
      RoundhouseUi.job_tags = Tags.from_constant(:OWNER, as: :squad)
      assert_equal Tags::EMPTY, Tags.for(klass: "../../etc/passwd", item: {})
      assert_equal Tags::EMPTY, Tags.for(klass: "A" * 500, item: {})
    ensure
      RoundhouseUi.job_tags = nil
    end

    def test_runbook_resolvers_do_not_constantize_hostile_names
      RoundhouseUi.job_runbooks = Runbooks.from_constant(:RUNBOOK)
      assert_nil Runbooks.for("../../etc/passwd")
      assert_nil Runbooks.for("A" * 500)
    ensure
      RoundhouseUi.job_runbooks = nil
    end
  end
end

module JobClassFixtures
  class Owned
    OWNER = :payments
  end
end
