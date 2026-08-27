require "test_helper"

module RoundhouseUi
  # Six sites hand-enumerated the filters into URLs and forms. Adding `class=` and
  # `error=` updated three of them, and the confirm form was one of the misses — so
  # a dry run listing two jobs POSTed a request that deleted five, and reported
  # "Deleted 5 matching job(s)" as though that had been approved.
  #
  # `active_filters` / `filter_params` / `filter_url` start from ALL of them and
  # name only the delta, so dropping one is not expressible. This test is what
  # stops anyone going back to a list — including me, since I fixed six sites and
  # wrote a behavioural test for exactly one of them.
  class FilterTransportTest < ActiveSupport::TestCase
    ROOT = RoundhouseUi::Engine.root

    # Spellings that mean "I am building a filtered URL or form by hand".
    HAND_ROLLED = [
      /\bq:\s*@query/, /\bq:\s*params\[:q\]/,
      /\btag:\s*params\[:tag\]/, /\bqueue:\s*params\[:queue\]/,
      /name="tag"/, /name="queue"/, /name="class"/, /name="error"/
    ].freeze

    # Each exemption is a decision, with the reason, not a way to quiet the test.
    ALLOWED = {
      # ErrorsController does not include JobSetBrowsing either: it has q and tag
      # and no class/error/queue, because a row already IS a class+error group.
      "app/views/roundhouse_ui/errors/index.html.erb" =>
        "grouped errors carry only q and tag; active_filters is not available here",
      # `name="queue"` here is a job ATTRIBUTE being edited, not a filter.
      "app/views/roundhouse_ui/jobs/_form.html.erb" =>
        "the queue field of a job being edited, not a filter"
    }.freeze

    def files
      Dir[ROOT.join("app/views/**/*.erb"), ROOT.join("app/helpers/**/*.rb")].sort
    end

    def test_nothing_enumerates_filter_params_by_hand
      offenders = files.flat_map do |path|
        rel = path.sub(ROOT.to_s + "/", "")
        next [] if ALLOWED.key?(rel)

        File.readlines(path).each_with_index.filter_map do |line, i|
          next if line.lstrip.start_with?("#", "<%#")

          hits = HAND_ROLLED.count { |re| line.match?(re) }
          "#{rel}:#{i + 1} — #{line.strip[0, 90]}" if hits.positive?
        end
      end

      assert_empty offenders, <<~WHY
        These build a filtered URL or form by naming filters one at a time:

          #{offenders.join("\n          ")}

        Use filter_url / filter_params / active_filters. They start from every
        active filter, so the next one added cannot be silently dropped — which is
        how the confirm form came to destroy more jobs than its dry run displayed.
      WHY
    end

    def test_the_filter_key_list_covers_every_filter_the_scan_reads
      # If a filter is honoured by entry_selected? but missing from FILTER_KEYS, it
      # never reaches a URL — the browse would apply it and the bulk would not.
      predicate = File.read(ROOT.join("app/controllers/concerns/roundhouse_ui/job_set_browsing.rb"))
      body = predicate[/def entry_selected\?.*?\n    end/m]
      assert body, "could not find entry_selected?"

      read = body.scan(/@(\w+)_filter\b/).flatten.uniq.map(&:to_sym)
      read << :tag if body.include?("entry_tagged?")
      read << :q   if body.include?("entry_matches?")

      missing = read - JobSetBrowsing::FILTER_KEYS
      assert_empty missing,
        "entry_selected? honours #{missing.join(', ')} but FILTER_KEYS omits them, " \
        "so no URL or form carries them and the dry run and the action will diverge."
    end

    # The filter now travels as ONE parameter, so "the form carried four of the
    # five" is not a shape a link or a form can take any more. What replaces the
    # old source scan is the property that actually matters, asserted end to end:
    # whatever a URL says, parsed, is what gets applied — which is also exactly
    # what makes a filtered URL safe to paste to a colleague.
    class Harness
      include RoundhouseUi::ApplicationHelper
      def initialize(query) = @filter = query
      def active_filters = { q: @filter.to_s.presence }.compact
    end

    FULL = "class=EmbeddingWorker error=KeyError queue=ai tag=squad:platform stripe".freeze

    def test_a_filtered_url_round_trips_through_the_wire
      # Percent-encode and decode it exactly as a browser would, because the
      # separator is `=` and every facet therefore rides inside a value.
      params = Harness.new(FilterQuery.parse(FULL)).filter_params
      wire = Rack::Utils.build_query(params.transform_keys(&:to_s))
      back = FilterQuery.from_params(Rack::Utils.parse_nested_query(wire).symbolize_keys)

      assert_equal FULL, back.to_s, "a pasted URL must reconstruct the filter exactly"
      refute back.invalid?
    end

    def test_the_whole_filter_is_one_parameter
      assert_equal [ :q ], Harness.new(FilterQuery.parse(FULL)).filter_params.keys,
        "more than one filter parameter is how a form comes to carry only some of them"
    end

    def test_a_facet_override_edits_the_query_rather_than_adding_a_parameter
      h = Harness.new(FilterQuery.parse(FULL))

      cleared = FilterQuery.parse(h.filter_params(class: nil)[:q])
      assert_nil cleared.klass, "the × must remove the facet FROM q, not send class=nil beside it"
      assert_equal "KeyError", cleared.error, "and must remove only the one it names"
      assert_equal "stripe", cleared.text

      swapped = FilterQuery.parse(h.filter_params(tag: "squad:core")[:q])
      assert_equal "squad:core", swapped.tag
    end

    def test_transport_keys_pass_through_and_nil_ones_drop_out
      h = Harness.new(FilterQuery.parse("class=A"))
      assert_equal({ q: "class=A", page: 2 }, h.filter_params(page: 2))
      assert_equal({ q: "class=A" }, h.filter_params(page: nil), "page: nil means page one")
    end

    def test_every_facet_is_reachable_from_a_link
      # A facet honoured by the parser but absent from FACET_OVERRIDES has no × and
      # no chip that can set it — applied by URL, unremovable by click.
      unreachable = (FilterQuery::KEYS - [ "text" ]).reject do |key|
        ApplicationHelper::FACET_OVERRIDES.key?(key.to_sym)
      end
      assert_empty unreachable,
        "#{unreachable.join(', ')} can be filtered on but not cleared from a link"
    end

    def test_a_legacy_five_parameter_url_still_resolves
      # Somebody has these bookmarked, and find_like_link emitted them for months.
      back = FilterQuery.from_params({ class: "EmbeddingWorker", error: "KeyError",
                                      queue: "ai", tag: "squad:platform", q: "stripe" })
      assert_equal FULL, back.to_s
    end

    def test_a_legacy_parameter_contradicting_q_refuses_rather_than_picking_one
      back = FilterQuery.from_params({ q: "class=A", class: "B" })
      assert back.invalid?, "silently preferring one would scope a Delete to a filter nobody chose"
      refute back.any?
    end
  end
end
