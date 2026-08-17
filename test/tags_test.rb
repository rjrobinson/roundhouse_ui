require "test_helper"

# Named classes so the constant convention has something real to constantize.
class TagsTestOwnedJob
  OWNER = :growth
end

class TagsTestBaseJob
  OWNER = :platform
end

class TagsTestChildJob < TagsTestBaseJob; end

class TagsTestPlainJob; end

module RoundhouseUi
  class TagsTest < ActiveSupport::TestCase
    def teardown
      RoundhouseUi.job_tags = nil
      RoundhouseUi.job_tags_per_job = false
      RoundhouseUi.tag_filters = nil
      RoundhouseUi.redact_args = []
    end

    def test_no_resolver_means_no_tags
      assert_equal({}, Tags.for(klass: "TagsTestOwnedJob", item: {}))
    end

    def test_from_constant_reads_the_convention
      RoundhouseUi.job_tags = Tags.from_constant(:OWNER, as: :squad)
      assert_equal({ "squad" => "growth" }, Tags.for(klass: "TagsTestOwnedJob", item: {}))
    end

    def test_from_constant_defaults_the_tag_key_to_the_constant_name
      RoundhouseUi.job_tags = Tags.from_constant(:OWNER)
      assert_equal({ "owner" => "growth" }, Tags.for(klass: "TagsTestOwnedJob", item: {}))
    end

    def test_from_constant_skips_classes_without_the_constant
      RoundhouseUi.job_tags = Tags.from_constant(:OWNER, as: :squad)
      assert_equal({}, Tags.for(klass: "TagsTestPlainJob", item: {}))
    end

    def test_from_constant_sees_inherited_constants
      RoundhouseUi.job_tags = Tags.from_constant(:OWNER, as: :squad)
      assert_equal({ "squad" => "platform" }, Tags.for(klass: "TagsTestChildJob", item: {}))
    end

    def test_from_constant_ignores_unresolvable_class_names
      RoundhouseUi.job_tags = Tags.from_constant(:OWNER, as: :squad)
      assert_equal({}, Tags.for(klass: "NoSuchJobAnywhere", item: {}))
    end

    def test_output_is_normalized_to_string_keys_and_values
      RoundhouseUi.job_tags = ->(klass:, item:) { { squad: :growth, "shard" => 3 } }
      assert_equal({ "squad" => "growth", "shard" => "3" }, Tags.for(klass: "TagsTestPlainJob", item: {}))
    end

    def test_nil_and_non_hash_returns_mean_no_tags
      RoundhouseUi.job_tags = ->(klass:, item:) { }
      assert_equal({}, Tags.for(klass: "TagsTestPlainJob", item: {}))

      RoundhouseUi.job_tags = ->(klass:, item:) { "growth" }
      assert_equal({}, Tags.for(klass: "TagsTestPlainJob", item: {}))
    end

    def test_a_raising_resolver_never_breaks_and_yields_no_tags
      RoundhouseUi.job_tags = ->(klass:, item:) { raise "host bug" }
      assert_equal({}, Tags.for(klass: "TagsTestPlainJob", item: {}))
    end

    def test_the_activejob_wrapper_is_unwrapped_before_the_resolver_sees_it
      seen = nil
      RoundhouseUi.job_tags = ->(klass:, item:) { seen = klass and nil }
      Tags.for(klass: "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper",
               item: { "wrapped" => "TagsTestOwnedJob" })
      assert_equal "TagsTestOwnedJob", seen
    end

    def test_class_cached_mode_memoizes_per_class
      calls = 0
      RoundhouseUi.job_tags = ->(klass:, item:) { calls += 1 and { squad: :growth } }
      cache = {}
      2.times { Tags.for(klass: "TagsTestOwnedJob", item: {}, cache: cache) }
      assert_equal 1, calls
    end

    def test_class_cached_mode_withholds_the_item
      seen = :unset
      RoundhouseUi.job_tags = ->(klass:, item:) { seen = item and nil }
      Tags.for(klass: "TagsTestOwnedJob", item: { "args" => [ 1 ] }, cache: {})
      assert_nil seen
    end

    def test_per_job_mode_passes_the_item_and_skips_the_cache
      calls = 0
      seen = nil
      RoundhouseUi.job_tags_per_job = true
      RoundhouseUi.job_tags = ->(klass:, item:) { calls += 1; seen = item; { tenant: item["args"].first } }
      cache = {}
      2.times { Tags.for(klass: "TagsTestOwnedJob", item: { "args" => [ "acme" ] }, cache: cache) }
      assert_equal 2, calls
      assert_equal({ "args" => [ "acme" ] }, seen)
      assert_empty cache
    end

    def test_tag_values_pass_through_redact_args_masking
      RoundhouseUi.redact_args = %w[tenant]
      RoundhouseUi.job_tags = ->(klass:, item:) { { tenant: "acme-corp", squad: :growth } }
      tags = Tags.for(klass: "TagsTestPlainJob", item: {})
      assert_equal Redaction::MASK, tags["tenant"]
      assert_equal "growth", tags["squad"]
    end

    def test_filters_is_nil_when_nothing_is_declared
      assert_nil Tags.filters
    end

    def test_filters_normalizes_declared_vocabulary
      RoundhouseUi.tag_filters = { squad: %i[core growth] }
      assert_equal({ "squad" => %w[core growth] }, Tags.filters)
    end

    def test_filters_accepts_callable_values_and_a_callable_whole
      RoundhouseUi.tag_filters = { squad: -> { %w[core growth] } }
      assert_equal({ "squad" => %w[core growth] }, Tags.filters)

      RoundhouseUi.tag_filters = -> { { "squad" => %w[ops] } }
      assert_equal({ "squad" => %w[ops] }, Tags.filters)
    end

    def test_a_raising_vocabulary_resolves_to_nil
      RoundhouseUi.tag_filters = -> { raise "host bug" }
      assert_nil Tags.filters
    end

    def test_match_compares_normalized_values
      tags = { "squad" => "growth" }
      assert Tags.match?(tags, :squad, :growth)
      assert Tags.match?(tags, "squad", "growth")
      refute Tags.match?(tags, "squad", "core")
      refute Tags.match?(tags, "team", "growth")
    end

    def test_match_on_a_redacted_tag_only_matches_the_mask
      RoundhouseUi.redact_args = %w[tenant]
      RoundhouseUi.job_tags = ->(klass:, item:) { { tenant: "acme-corp" } }
      tags = Tags.for(klass: "TagsTestPlainJob", item: {})
      refute Tags.match?(tags, "tenant", "acme-corp")
      assert Tags.match?(tags, "tenant", Redaction::MASK)
    end
  end
end
