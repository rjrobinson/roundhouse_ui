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

        assert_match "class=BillingWorker&amp;error=Timeout%3A%3AError", markup,
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

        assert_match "class=W", markup
        refute_match "error=", markup
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

        assert_match "rh-filter-chip", markup, "no chip shows the active filter"
        assert_match "BillingWorker", markup
        assert_match "Clear the class filter", markup
        assert_match "Clear the error filter", markup
      end
    end

    def test_clearing_the_error_keeps_the_class
      with_dead do
        get "/roundhouse/dead", params: { class: "BillingWorker", error: "Timeout::Error" }

        clear = markup[/href="([^"]*)"[^>]*class="x"[^>]*title="Clear the error filter"/, 1] ||
                markup[/<a[^>]*title="Clear the error filter"[^>]*href="([^"]*)"/, 1]
        refute_nil clear, "no clear link for the error half"
        assert_includes clear, "class=BillingWorker", "clearing the error dropped the class too"
        refute_includes clear, "error=", "clearing the error left it in the URL"
      end
    end

    def test_clearing_the_class_clears_both
      with_dead do
        get "/roundhouse/dead", params: { class: "BillingWorker", error: "Timeout::Error" }

        clear = markup[/<a[^>]*title="Clear the class filter"[^>]*href="([^"]*)"/, 1] ||
                markup[/href="([^"]*)"[^>]*title="Clear the class filter"/, 1]
        refute_nil clear
        refute_includes clear, "class=", "the class filter survived its own clear link"
        refute_includes clear, "error=", "an error filter without a class matches nothing useful"
      end
    end

    def test_searching_does_not_drop_the_glass_filter
      # The form carries tag and queue as hidden inputs; without class and error it
      # silently discarded the filter the moment you typed anything.
      with_dead do
        get "/roundhouse/dead", params: { class: "BillingWorker", error: "Timeout::Error" }

        form = markup[/<form[^>]*class="rh-search".*?<\/form>/m].to_s
        refute_empty form
        assert_match(/name="class" value="BillingWorker"/, form,
          "a search would drop the class filter")
        assert_match(/name="error" value="Timeout::Error"/, form,
          "a search would drop the error filter")
      end
    end

    def test_no_chip_when_nothing_is_filtered
      with_dead do
        get "/roundhouse/dead"
        refute_match "rh-filter-chip", markup
      end
    end
  end
end
