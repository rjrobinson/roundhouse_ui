require "test_helper"

module RoundhouseUi
  # The help panel exists because the grammar REFUSES what it does not understand
  # instead of falling back to a substring search. That makes it documentation the
  # box cannot work without — and documentation that drifts is worse than none,
  # because every example in it is offered as copy-pasteable.
  class SearchHelpTest < ActiveSupport::TestCase
    ROOT = RoundhouseUi::Engine.root
    PANEL = ROOT.join("app/views/roundhouse_ui/shared/_search_help.html.erb")
    LAYOUT = ROOT.join("app/views/layouts/roundhouse_ui/application.html.erb")

    def panel = @panel ||= File.read(PANEL)
    def examples = panel.scan(%r{<code>(.*?)</code>}m).flatten.map { |e| CGI.unescapeHTML(e) }

    # THE test. Every example is offered as something to type, so every example has
    # to survive being typed. Nothing else in the suite would notice if a grammar
    # change turned this panel into a page of instructions that do not work.
    def test_every_example_actually_parses
      queries = examples.select { |e| e.include?("=") }
      refute_empty queries, "the panel documents a grammar and shows no queries"

      queries.each do |example|
        q = FilterQuery.parse(example)
        refute q.invalid?, "the help offers #{example.inspect}, which the parser refuses: #{q.message}"
        refute q.degraded?, "the help offers #{example.inspect}, which drops a facet: #{q.notes.join(' ')}"
        assert q.any?, "the help offers #{example.inspect}, which selects nothing at all"
      end
    end

    # An example that round-trips differently from how it is written is an example
    # that changes meaning the moment you press Enter twice.
    def test_every_example_round_trips_as_written
      examples.select { |e| e.include?("=") }.each do |example|
        q = FilterQuery.parse(example)
        assert_equal q, FilterQuery.parse(q.to_s), example.inspect
      end
    end

    def test_every_filter_key_is_documented
      documented = panel.scan(/<dt>([a-z]+)=<\/dt>/).flatten
      # `text` is documented in prose as the escape hatch rather than as a row of
      # the table: it is not a filter you reach for, it is the way out of one.
      missing = FilterQuery::KEYS - documented - [ "text" ]
      assert_empty missing,
        "#{missing.join(', ')} can be typed into the box and is not documented — the " \
        "grammar refuses what it does not know, so an undocumented key is a dead end."
      assert_includes panel, 'text="account_id=1234"', "the escape hatch must be shown verbatim"
    end

    # What the bar offers to complete, and — more importantly — what it must not.
    #
    # class= and error= values can only be enumerated by reading every entry in the
    # set. browse deliberately reads one page, so offering them would turn opening a
    # 50k dead set into a full scan on every render. The JS suite cannot pin this:
    # it uses its own fixture vocabulary, so only a Ruby test sees the real one.
    class VocabHarness
      include RoundhouseUi::ApplicationHelper
      def initialize(queues: nil, name: nil) = (@queues = queues; @name = name)
    end

    def test_the_completion_vocabulary_offers_only_what_is_free
      RoundhouseUi.tag_filters = { squad: %w[core platform] }
      vocab = VocabHarness.new(queues: [ Struct.new(:name).new("ai"), Struct.new(:name).new("default") ]).filter_vocabulary

      assert_equal %w[squad:core squad:platform], vocab["tag"]
      assert_equal %w[ai default], vocab["queue"]
      refute vocab.key?("class"),
        "class= values need a whole-set scan; offering them makes every render read the set"
      refute vocab.key?("error"), "error= values need a whole-set scan"
      refute vocab.key?("text"), "text= is an escape hatch, not a vocabulary"
    ensure
      RoundhouseUi.tag_filters = nil
    end

    def test_the_vocabulary_is_empty_rather_than_wrong_when_nothing_is_known
      RoundhouseUi.tag_filters = nil
      assert_equal({}, VocabHarness.new.filter_vocabulary,
        "no declared tags and no loaded queues must offer nothing, not guess")
    end

    def test_a_queue_page_can_complete_its_own_queue
      assert_equal [ "mailers" ], VocabHarness.new(name: "mailers").filter_vocabulary["queue"]
    end

    # Five pages had five hand-written placeholders — "search class, jid, error, or
    # arg value…", "filter by job class, error, or squad…", "filter queues by name…"
    # — and not one of them mentioned that `class=` was a thing you could type. The
    # placeholder is generated from the page's own key list now, so it names exactly
    # what that page honours and cannot go stale when the grammar changes.
    def test_the_placeholder_names_exactly_the_keys_the_page_honours
      RoundhouseUi.job_tags = ->(klass:, item:) { { squad: "core" } }
      h = VocabHarness.new

      full = h.filter_placeholder(FilterQuery::KEYS, noun: "arguments")
      %w[class= error= queue= tag=].each { |k| assert_includes full, k }
      refute_includes full, "text=", "text= is the escape hatch, not an advertised filter"
      assert_includes full, "arguments", "the page's own noun must survive"

      # Errors has no queue facet: a klass|error group spans every queue.
      errors = h.filter_placeholder(ErrorsController::FILTER_KEYS, noun: "class, error or squad")
      refute_includes errors, "queue=", "the hint must not offer a filter the parser refuses here"
      assert_includes errors, "class="

      queues = h.filter_placeholder(QueuesController::INDEX_FILTER_KEYS, noun: "queue names")
      assert_includes queues, "queue="
      refute_includes queues, "class=", "a queue is not a job"
    ensure
      RoundhouseUi.job_tags = nil
    end

    def test_the_placeholder_hides_tag_when_no_host_declared_one
      RoundhouseUi.job_tags = nil
      refute_includes VocabHarness.new.filter_placeholder, "tag=",
        "offering tag= with no resolver configured advertises a filter that matches nothing"
    end

    def test_no_page_hand_writes_a_placeholder
      # Both spellings: `placeholder="…"` in markup, and `placeholder:` passed to the
      # bar — which the bar no longer reads at all, so passing one is a hint that
      # silently does nothing. Catching only the first let a mutation through.
      offenders = (GRAMMAR_PAGES + SUBSTRING_PAGES).select do |page|
        File.read(ROOT.join("app/views/roundhouse_ui/#{page}.html.erb")).match?(/placeholder[=:]/)
      end
      assert_empty offenders,
        "#{offenders.join(', ')} spell out a placeholder by hand; five of those went stale " \
        "the day the grammar shipped. Pass `noun:` and let filter_placeholder build it."
    end

    def test_every_page_with_a_search_box_uses_the_same_bar
      (GRAMMAR_PAGES + SUBSTRING_PAGES).each do |page|
        body = File.read(ROOT.join("app/views/roundhouse_ui/#{page}.html.erb"))
        assert_includes body, "shared/search_bar", "#{page} has its own search markup"
        refute_match(/<input type="search"/, body, "#{page} still hand-rolls an input")
      end
    end

    def test_it_says_filters_are_exact_and_that_underscore_is_not_a_wildcard
      # The two properties someone can lose money on. Whitespace-tolerant, because
      # the sentence wraps and a hard-coded single space made this fail on a reword.
      assert_match(/matche?s?\s+<strong>exactly<\/strong>/, panel,
        "the panel must say a bare filter is exact, next to the bulk controls")
      assert_match(/wildcard/, panel, "% is supported and has to be documented")
      assert_match(/<code>_<\/code>\s+is a literal/, panel,
        "_ being literal is the difference between queue=default_low filtering and " \
        "silently becoming a pattern — say it where the wildcard is introduced")
    end

    # Hover was the ask. Hover ALONE would put the vocabulary of a refusing grammar
    # out of reach of anyone on a keyboard or a touch screen.
    def test_the_panel_opens_on_focus_as_well_as_hover
      css = File.read(LAYOUT)
      rule = css[/\.rh-help:hover \.rh-help-panel[^{]*\{[^}]*\}/]
      assert rule, "no reveal rule for the help panel"
      assert_includes rule, ":focus-within",
        "hover-only help is unreachable by keyboard and absent on touch"
    end

    def test_it_needs_no_javascript
      refute_match(/<script|onclick|onmouseover/, panel,
        "a popover that needs a script stops opening the day a nonce slips")
    end

    # Shown where the grammar applies, and NOWHERE ELSE. Queues-index filters queue
    # names and Errors filters groups; both take a plain substring, so a panel
    # promising class= there documents behaviour those pages do not have.
    GRAMMAR_PAGES = %w[dead/index retries/index scheduled/index queues/show errors/index].freeze
    SUBSTRING_PAGES = %w[queues/index].freeze

    BAR = ROOT.join("app/views/roundhouse_ui/shared/_search_bar.html.erb")

    def test_the_help_is_on_every_grammar_page
      # Reached through the bar, which is the control it documents — so the two
      # cannot be rendered apart.
      assert_includes File.read(BAR), "shared/search_help", "the bar offers no help"
      GRAMMAR_PAGES.each do |page|
        body = File.read(ROOT.join("app/views/roundhouse_ui/#{page}.html.erb"))
        assert_includes body, "shared/search_bar", "#{page} takes the grammar and has no filter bar"
      end
    end

    def test_the_help_is_not_shown_where_the_grammar_does_not_apply
      SUBSTRING_PAGES.each do |page|
        body = File.read(ROOT.join("app/views/roundhouse_ui/#{page}.html.erb"))
        refute_includes body, "shared/search_help",
          "#{page} searches by substring; this panel would promise filters it does not honour"
      end
    end
  end
end
