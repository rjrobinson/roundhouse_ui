require "test_helper"

module RoundhouseUi
  # "Find more like this" narrows to one class and, where the set records one, one
  # error — the same pair the Errors page calls a single issue.
  #
  # The filters are exact on purpose. This button exists to reveal the bulk
  # Retry/Delete controls, so anything it selects is a candidate for deletion; a
  # substring here would let "delete all matching" reach jobs whose arguments
  # merely mention the class that was clicked.
  class FindLikeTest < ActionDispatch::IntegrationTest
    class Entry
      attr_reader :klass, :jid, :item, :queue, :at
      def initialize(klass:, jid:, error: nil, queue: "default")
        @klass, @jid, @queue, @at = klass, jid, queue, Time.now
        @item = { "class" => klass, "args" => [], "jid" => jid, "queue" => queue,
                  "error_class" => error, "error_message" => error && "boom" }
      end
      def args = []
    end

    class Set
      include Enumerable
      def initialize(entries) = @entries = entries
      def each(&blk) = @entries.each(&blk)
      def size = @entries.size
    end

    ENTRIES = [
      Entry.new(klass: "BillingWorker", jid: "a1", error: "Timeout::Error"),
      Entry.new(klass: "BillingWorker", jid: "a2", error: "Timeout::Error"),
      Entry.new(klass: "BillingWorker", jid: "a3", error: "ArgumentError"),
      # A longer name that CONTAINS the one above: the case a substring filter
      # would wrongly sweep in, and the reason these are exact.
      Entry.new(klass: "BillingWorkerLegacy", jid: "b1", error: "Timeout::Error"),
      Entry.new(klass: "MailerWorker", jid: "c1", error: "Timeout::Error")
    ].freeze

    def with_dead(&blk) = stub_method(Sidekiq::DeadSet, :new, Set.new(ENTRIES), &blk)

    def markup = response.body.split("</style>").last.to_s

    # Just the places the page names the active filter back to you. Asserting
    # against the whole page is wrong: every row's glass carries the same words in
    # its own title, so a page-wide refute can never pass.
    def filter_labels
      markup.scan(/class="(?:hint|rh-actionlabel)"[^>]*>(.*?)<\/span>/m).flatten.join(" ")
    end
    # The header checkbox is aria-label="select all"; drop it.
    def jids_shown = markup.scan(/aria-label="select ([^"]+)"/).flatten - [ "all" ]

    def test_the_glass_links_to_this_class_and_error
      with_dead do
        get "/roundhouse/dead"

        # One parameter now: q= carries the whole filter, so `=` rides inside a
        # value and arrives percent-encoded.
        assert_match "q=class%3DBillingWorker+error%3DTimeout%3A%3AError", markup,
          "the glass must carry both halves of the fingerprint"
        assert_match "Find more BillingWorker failing with Timeout::Error", markup
      end
    end

    def test_every_row_offers_it
      with_dead do
        get "/roundhouse/dead"
        assert_equal ENTRIES.size, markup.scan(/title="Find more /).size
      end
    end

    def test_the_class_filter_is_exact_and_not_a_substring
      with_dead do
        get "/roundhouse/dead", params: { class: "BillingWorker" }

        assert_equal %w[a1 a2 a3], jids_shown,
          "BillingWorkerLegacy was swept in by a class filter that should be exact"
      end
    end

    def test_class_and_error_together_narrow_to_the_one_issue
      with_dead do
        get "/roundhouse/dead", params: { class: "BillingWorker", error: "Timeout::Error" }

        assert_equal %w[a1 a2], jids_shown, "the error half of the fingerprint was ignored"
      end
    end

    def test_the_error_filter_is_also_exact
      with_dead do
        get "/roundhouse/dead", params: { class: "BillingWorker", error: "Timeout" }

        assert_empty jids_shown, "a partial error name must match nothing, not everything"
      end
    end

    def test_the_bulk_controls_appear_for_this_filter_alone
      with_dead do
        get "/roundhouse/dead"
        refute_match "All 5", markup, "no filter, so there is nothing to act on in bulk"

        get "/roundhouse/dead", params: { class: "BillingWorker" }
        assert_match "like BillingWorker", filter_labels,
          "the filter must be named back, since bulk Delete acts on exactly it"
        assert_match(/bulk|preview/, markup, "the bulk controls did not render")
      end
    end

    def test_the_description_distinguishes_class_only_from_class_plus_error
      with_dead do
        get "/roundhouse/dead", params: { class: "BillingWorker" }
        assert_match "like BillingWorker", filter_labels
        refute_match "failing with", filter_labels,
          "no error was filtered on, so the description must not claim one"

        get "/roundhouse/dead", params: { class: "BillingWorker", error: "ArgumentError" }
        assert_match "like BillingWorker failing with ArgumentError", filter_labels
      end
    end

    def test_scheduled_offers_the_class_alone
      # Scheduled jobs have not failed, so there is no error half to match on.
      stub_method(Sidekiq::ScheduledSet, :new, Set.new([ Entry.new(klass: "W", jid: "s1") ])) do
        get "/roundhouse/scheduled"

        assert_match "q=class%3DW", markup
        refute_match "error%3D", markup
        assert_match "Find more W", markup
      end
    end
    # The glass sets a filter you cannot see in the search box, so it needs a way
    # out. Reported as "populate the search bar so we can clear that search" — the
    # box itself is the wrong home for it, because ?q= is a substring match sitting
    # directly above "delete all matching".
    def test_the_active_filter_is_shown_and_can_be_cleared
      with_dead do
        get "/roundhouse/dead", params: { class: "BillingWorker", error: "Timeout::Error" }

        assert_match %q(class="rh-pillf"), markup, "no chip shows the active filter"
        assert_match "BillingWorker", markup
        assert_match "Remove the class filter", markup
        assert_match "Remove the error filter", markup
      end
    end

    def test_clearing_the_error_keeps_the_class
      with_dead do
        get "/roundhouse/dead", params: { class: "BillingWorker", error: "Timeout::Error" }

        clear = markup[/href="([^"]*)"[^>]*class="x"[^>]*title="Remove the error filter"/, 1] ||
                markup[/<a[^>]*title="Remove the error filter"[^>]*href="([^"]*)"/, 1]
        refute_nil clear, "no clear link for the error half"
        assert_includes clear, "class%3DBillingWorker", "clearing the error dropped the class too"
        refute_includes clear, "error%3D", "clearing the error left it in the URL"
      end
    end

    def test_clearing_the_class_keeps_the_error
      # This asserted the opposite, on the reasoning that an error filter alone was
      # useless. It is not: "every Timeout::Error, whatever the class" is a real
      # question, and a × that removes something you did not point at is wrong.
      with_dead do
        get "/roundhouse/dead", params: { class: "BillingWorker", error: "Timeout::Error" }

        clear = markup[/<a[^>]*title="Remove the class filter"[^>]*href="([^"]*)"/, 1] ||
                markup[/href="([^"]*)"[^>]*title="Remove the class filter"/, 1]
        refute_nil clear
        refute_includes clear, "class%3D", "the class filter survived its own clear link"
        assert_includes clear, "error%3DTimeout", "clearing the class took the error with it"
      end
    end

    def test_an_error_filter_stands_on_its_own
      with_dead do
        get "/roundhouse/dead", params: { error: "Timeout::Error" }

        assert_equal %w[a1 a2 b1 c1], jids_shown,
          "an error-only filter must select every class with that error"
        assert_match "failing with Timeout::Error", filter_labels,
          "an active filter that the page does not name is an invisible filter"
        assert_match %q(class="rh-pillf"), markup, "no chip, so no way to clear it"
      end
    end

    def test_searching_does_not_drop_the_glass_filter
      # The form used to carry tag and queue as hidden inputs and not class or error,
      # so typing anything silently discarded the glass's filter.
      #
      # Asserted as the property rather than the shape: the bar now shows facets as
      # pills and leaves the visible input holding only the free text, so what
      # matters is that SUBMITTING it — every field it carries, fed back through the
      # one parse point — reconstructs the identical filter. A dropped pill, a
      # missing qf, or a mislabelled field all fail this.
      with_dead do
        get "/roundhouse/dead", params: { class: "BillingWorker", error: "Timeout::Error" }
        expected = RoundhouseUi::FilterQuery.from_params({ class: "BillingWorker", error: "Timeout::Error" })

        form = markup[/<form.*?class="rh-search".*?<\/form>/m].to_s
        refute_empty form
        fields = form.scan(/<input[^>]*name="(q|qf)"[^>]*value="([^"]*)"/)
                     .to_h { |name, value| [ name.to_sym, CGI.unescapeHTML(value) ] }

        assert_equal expected, RoundhouseUi::FilterQuery.from_params(fields),
          "submitting the bar unchanged produced #{RoundhouseUi::FilterQuery.from_params(fields).to_s.inspect} " \
          "instead of #{expected.to_s.inspect} — a search would drop part of the filter"
        # And the facets must be VISIBLE while they are in force, or the bar is back
        # to holding a filter you cannot see.
        assert_equal 2, markup.scan(/class="rh-pillf"/).size, "both facets need a pill"
      end
    end

    def test_typing_into_a_filtered_bar_narrows_rather_than_replaces
      # The visible input holds only the text, so a facet must survive typing in it.
      with_dead do
        get "/roundhouse/dead", params: { q: "class=BillingWorker", qf: "", page: nil }
        form = markup[/<form.*?class="rh-search".*?<\/form>/m].to_s
        qf = form[/name="qf" value="([^"]*)"/, 1]
        assert_equal "class=BillingWorker", CGI.unescapeHTML(qf.to_s)

        # Simulate the submit: the facet companion plus what was typed.
        combined = RoundhouseUi::FilterQuery.from_params({ qf: qf, q: "stripe" })
        assert_equal "class=BillingWorker stripe", combined.to_s
        refute combined.invalid?
      end
    end

    def test_no_chip_when_nothing_is_filtered
      with_dead do
        get "/roundhouse/dead"
        refute_match %q(class="rh-pillf"), markup
      end
    end
    def test_a_clear_all_removes_every_filter_at_once
      with_dead do
        get "/roundhouse/dead", params: { class: "BillingWorker", error: "Timeout::Error", q: "90210" }

        href = markup[/<a[^>]*class="rh-bar-clear"[^>]*href="([^"]*)"/, 1] ||
               markup[/href="([^"]*)"[^>]*class="rh-bar-clear"/, 1]
        refute_nil href, "no clear-all; two filters need a way out in one click"
        refute_includes href, "class=", "clear all left the class filter behind"
        refute_includes href, "error=", "clear all left the error filter behind"
        refute_includes href, "tag=", "clear all left the tag filter behind"
      end
    end

    def test_the_clear_control_is_a_real_target_not_a_glyph
      # It was 13px at --faint with 1px of padding, and went unnoticed. The chip is
      # the only way out of a filter the search box cannot show, so the way out has
      # to be clickable-looking.
      css = File.read(RoundhouseUi::Engine.root.join("app/views/layouts/roundhouse_ui/application.html.erb"))
      rule = css[/\.rh-filter-chip \.x \{([^}]*)\}/m, 1]
      assert rule, "no rule for the chip's clear control"
      assert_match(/width:\s*\d+px/, rule, "the clear control has no hit area")
      assert_match(/height:\s*\d+px/, rule, "the clear control has no hit area")
      refute_match(/color:var\(--faint\)/, rule, "--faint is the dimmest token; this went unnoticed at it")
    end
  end
end
