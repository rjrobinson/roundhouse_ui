require "test_helper"

module RoundhouseUi
  # The whole grammar as a decision table. Pure Ruby, no request, no Redis — the
  # parser is the one piece of this feature that can be tested exhaustively and
  # cheaply, and it is the piece that decides what a Delete acts on.
  class FilterQueryTest < ActiveSupport::TestCase
    def parse(q) = FilterQuery.parse(q)

    ACCEPTED = {
      # colons are data, never delimiters — the reason the separator is = and not :
      "class=Billing::SyncWorker"                       => { klass: "Billing::SyncWorker", text: "" },
      "error=Timeout::Error"                            => { error: "Timeout::Error", text: "" },
      # a quoted value may hold spaces AND colons AND angle brackets
      %(error="Net::ReadTimeout with #<TCPSocket>")     => { error: "Net::ReadTimeout with #<TCPSocket>", text: "" },
      # facets lead, then one verbatim slice of text
      "class=BillingWorker error=Timeout::Error stripe" => { klass: "BillingWorker", error: "Timeout::Error", text: "stripe" },
      # the residue is a SLICE, so interior spacing survives
      "queue=default_low  alpha  beta"                  => { queue: "default_low", text: "alpha  beta" },
      "tag=squad:core"                                  => { tag: "squad:core", text: "" },
      # LIKE-style wildcards. Round-tripped by the shared test below, so what the
      # pill displays is what the next Enter applies.
      "class=Roundhouse%"                               => { klass: "Roundhouse%", text: "" },
      "class=%oundhouse%"                               => { klass: "%oundhouse%", text: "" },
      "error=%Timeout"                                  => { error: "%Timeout", text: "" },
      "class=Round%Worker queue=ai"                     => { klass: "Round%Worker", queue: "ai", text: "" },
      "tag=squad:plat%"                                 => { tag: "squad:plat%", text: "" },
      %(tag="squad:eu west")                            => { tag: "squad:eu west", text: "" },
      # the common paste: a whole error message. SSL_connect fails the lowercase key
      # charset at S, so nothing is a facet and the residue is the whole string.
      "SSL_connect returned=1 errno=0"                  => { text: "SSL_connect returned=1 errno=0" },
      # the escape hatch for facet-shaped text
      %(text="account_id=1234")                         => { text: "account_id=1234" },
      # an identical duplicate collapses; only a CONFLICTING one refuses
      "class=A class=A"                                 => { klass: "A", text: "" },
      "just some words"                                 => { text: "just some words" },
      ""                                                => { text: "" },
      "   "                                             => { text: "" },
      # free text may contain the operators; only a negated KNOWN facet is refused
      "-1 timeout"                                      => { text: "-1 timeout" },
      "a OR b"                                          => { text: "a OR b" },
      "50% * done"                                      => { text: "50% * done" }
    }.freeze

    REFUSED = {
      "clas=Foo"           => /Unknown filter "clas"/,
      "class="             => /needs a value/,
      %(class=" ")         => /needs a value/,
      "class=A class=B"    => /Two different values for class/,
      %(error="Net::Read)  => /Unclosed quote/,
      "-class=Foo"         => /Negation is not supported/,
      # `*` and `?` still refuse, and now teach the spelling that works.
      "class=Bill*"        => /Use % for a wildcard, not \*/,
      "error=Time?ut"      => /Use % for a wildcard/,
      # A pattern with no literal characters matches every possible value. It is not
      # a filter, but it renders as a pill that looks like one — the unfiltered-bulk
      # hole wearing a facet's clothing.
      "class=%"            => /matches everything, which is not a filter/,
      "queue=%%"           => /matches everything/,
      "class=a%b%c%d%e%f%g%h" => /at most 6 wildcards/,
      %(text="a" trailing) => /Text is given twice/
    }.freeze

    # A known key with a value it cannot use. Dropped rather than refused, so a typo
    # does not stop you browsing — and then flagged degraded, because what survived
    # selects a SUPERSET of what was typed and must authorise no bulk action.
    DEGRADED = {
      "tag=platform"                => { to_s: "", ignored: 1 },
      # A colon is not enough — both halves must be there. `tag=squad:` rendered a
      # pill, left tag_pair nil so entry_selected? selected everything, and reported
      # any_facets? true so the bulk controls stayed live.
      "tag=squad:"                  => { to_s: "", ignored: 1 },
      "tag=:core"                   => { to_s: "", ignored: 1 },
      "tag=:"                       => { to_s: "", ignored: 1 },
      "tag=garbage queue=default"   => { to_s: "queue=default", ignored: 1 },
      "tag=garbage stripe"          => { to_s: "stripe", ignored: 1 }
    }.freeze

    def test_a_known_key_with_an_unusable_value_is_dropped_not_refused
      DEGRADED.each do |input, want|
        q = parse(input)
        refute q.invalid?, "#{input.inspect} was refused: #{q.message}"
        assert q.degraded?, "#{input.inspect} dropped a facet without recording it"
        assert_equal want[:to_s], q.to_s, "#{input.inspect} canonical form"
        assert_equal want[:ignored], q.ignored.size
        assert_match(/tag= takes key:value/, q.notes.join(" "))
        # The dropped token must not survive as free text either: that would be a
        # third meaning for one string, and the canonical form above says otherwise.
        refute_includes q.text, "garbage"
      end
    end

    def test_a_clean_query_is_never_degraded
      [ "", "class=A", "tag=squad:core", "stripe", "tag=squad:core queue=ai x" ].each do |input|
        refute parse(input).degraded?, input.inspect
        assert_empty parse(input).notes, input.inspect
      end
    end

    def test_a_degraded_query_still_round_trips
      # It must, or the box would show one filter and the next Enter apply another.
      DEGRADED.each_key do |input|
        once = parse(input)
        assert_equal once, parse(once.to_s), "#{input.inspect} -> #{once.to_s.inspect}"
        refute parse(once.to_s).degraded?, "the cleaned form must be clean"
      end
    end

    def test_the_accepted_grammar
      ACCEPTED.each do |input, want|
        q = parse(input)
        refute q.invalid?, "#{input.inspect} was refused: #{q.message}"
        %i[klass error queue tag].each do |field|
          got = q.public_send(field)
          why = "#{input.inspect} -> #{field} should be #{want[field].inspect}, got #{got.inspect}"
          want[field].nil? ? assert_nil(got, why) : assert_equal(want[field], got, why)
        end
        assert_equal want.fetch(:text), q.text, "#{input.inspect} -> text"
      end
    end

    def test_the_refused_grammar
      REFUSED.each do |input, expected|
        q = parse(input)
        assert q.invalid?, "#{input.inspect} should have been refused, got #{q.to_s.inspect}"
        assert_match expected, q.message, "#{input.inspect} refused with the wrong reason"
        # A refusal selects nothing. It must never look like "no filter at all",
        # because "no filter" is what authorises a bulk action.
        refute q.any?, "#{input.inspect} was refused but still reports filters"
      end
    end

    # The property that makes the box the source of truth: what it shows, parsed, is
    # what gets applied. If these disagreed, the box could display one filter while
    # the Delete beneath it acted on another.
    def test_every_accepted_query_round_trips
      ACCEPTED.each_key do |input|
        once = parse(input)
        twice = parse(once.to_s)
        assert_equal once, twice,
          "#{input.inspect} -> #{once.to_s.inspect} -> #{twice.to_s.inspect} is not stable"
      end
    end

    def test_a_value_with_spaces_comes_back_quoted
      q = parse(%(error="Net::ReadTimeout with #<TCPSocket>"))
      assert_includes q.to_s, %("Net::ReadTimeout with #<TCPSocket>"),
        "unquoted, the round trip would reparse as a facet plus stray text"
      assert_equal q, parse(q.to_s)
    end

    def test_no_facets_means_the_text_is_what_it_always_was
      # This is what keeps every existing search and bookmark working unchanged.
      [ "PG::TooManyConnections", "a  b", "  padded  ", "50% of 100" ].each do |raw|
        assert_equal raw.strip, parse(raw).text, raw.inspect
      end
    end

    # ── wildcards ─────────────────────────────────────────────────────────────
    #
    # `%` only, and `_` is deliberately LITERAL. SQL's single-character wildcard
    # would turn queue=default_low into a pattern, and every name in this console is
    # underscore-dense — a wildcard nobody typed, scoping a Delete.
    PATTERNS = {
      "Roundhouse%"  => { yes: %w[Roundhouse RoundhouseWorker], no: %w[Xoundhouse ARoundhouse] },
      "%oundhouse%"  => { yes: %w[Roundhouse oundhouse XoundhouseY], no: %w[Round house] },
      "%Worker"      => { yes: %w[MyWorker Worker], no: %w[WorkerX Work] },
      "Round%Worker" => { yes: %w[RoundWorker RoundhouseWorker], no: %w[Round Worker RoundWorkerX] },
      # One literal must not do double duty: A%A needs TWO As.
      "A%A"          => { yes: %w[AA AxA], no: %w[A xA Ax] },
      "default_low"  => { yes: %w[default_low], no: %w[defaultXlow default_lowest default] }
    }.freeze

    def test_the_pattern_decision_table
      PATTERNS.each do |source, want|
        pattern = FilterQuery::Pattern.for(source)
        matcher = pattern || ->(v) { v == source }
        want[:yes].each do |v|
          assert (pattern ? pattern.match?(v) : v == source), "#{source.inspect} should match #{v.inspect}"
        end
        want[:no].each do |v|
          refute (pattern ? pattern.match?(v) : v == source), "#{source.inspect} must NOT match #{v.inspect}"
        end
      end
    end

    def test_an_underscore_is_literal_not_a_wildcard
      # The whole reason % was chosen over LIKE's full syntax.
      assert_nil FilterQuery::Pattern.for("default_low"), "_ must not compile to a pattern"
      q = parse("queue=default_low")
      assert q.matches_facet?(:queue, "default_low")
      refute q.matches_facet?(:queue, "defaultXlow")
    end

    def test_a_facet_without_a_wildcard_stays_exact
      # `queue=default` selecting `default_low` is the failure the exact-match rule
      # exists to prevent, and it feeds bulk_apply.
      q = parse("queue=default")
      assert q.matches_facet?(:queue, "default")
      refute q.matches_facet?(:queue, "default_low")
      refute q.wildcard?
    end

    def test_matches_facet_honours_the_wildcard
      q = parse("class=Round%Worker")
      assert q.wildcard?
      assert q.matches_facet?(:klass, "RoundhouseWorker")
      refute q.matches_facet?(:klass, "SomethingElse")
      # An absent facet matches everything, so the predicate can be a flat conjunction.
      assert q.matches_facet?(:error, "anything at all")
    end

    def test_a_wildcard_value_round_trips_verbatim
      # The pill shows the pattern; the pattern is what gets applied. If these
      # diverged the bar would display one scope and the Delete act on another.
      %w[class=Roundhouse% class=%oundhouse% error=%Timeout% tag=squad:plat%].each do |raw|
        once = parse(raw)
        assert_equal raw, once.to_s
        assert_equal once, parse(once.to_s)
      end
    end

    # ── bounds, checked before anything walks the input ───────────────────────
    def test_an_over_long_query_is_refused_not_truncated
      q = parse("x" * (FilterQuery::MAX_LENGTH + 1))
      assert q.invalid?
      assert_match(/too long/, q.message)
      refute q.any?, "truncation would select MORE, which is why it is refused"
    end

    def test_an_over_long_facet_value_is_refused
      q = parse("class=" + ("A" * (FilterQuery::MAX_VALUE + 1)))
      assert q.invalid?
      assert_match(/too long/, q.message)
    end

    def test_the_facet_count_is_bounded_by_the_key_set_itself
      # Five keys, and a conflicting duplicate refuses — so five is the ceiling and
      # no separate cap is needed. Asserted so that adding a sixth key is a
      # deliberate act rather than a silent widening of how much work one query can
      # ask for.
      assert_equal 5, FilterQuery::KEYS.size
      assert parse((1..6).map { |i| "queue=q#{i}" }.join(" ")).invalid?,
        "repeating a key with different values must refuse, not accumulate"
    end

    def test_a_quote_or_control_character_in_a_value_is_refused
      assert parse(%(class=A"B)).invalid?
      # Built rather than typed, so there is no literal control byte in this file.
      with_control = "class=A" + [ 7 ].pack("C") + "B"
      assert parse(with_control).invalid?
    end

    def test_a_non_string_is_refused_rather_than_coerced
      # ?q[]=a&q[]=b arrives as an Array; ?q[x]=1 as Parameters.
      assert parse([ "a", "b" ]).invalid?
      assert parse({ "x" => "1" }).invalid?
      refute parse(nil).invalid?, "no query at all is not an error"
    end

    def test_invalid_encoding_is_refused
      bad = [ 99, 108, 97, 115, 115, 61, 65, 255 ].pack("C*").force_encoding("UTF-8")
      assert parse(bad).invalid?
    end

    # ── the shapes the rest of the code consumes ──────────────────────────────
    def test_tag_pair_keeps_the_existing_two_element_shape
      assert_equal %w[squad core], parse("tag=squad:core").tag_pair
      assert_equal [ "squad", "eu west" ], parse(%(tag="squad:eu west")).tag_pair
      assert_nil parse("class=A").tag_pair
    end

    def test_chips_lists_only_active_facets_in_a_stable_order
      q = parse("error=Boom class=W queue=default")
      assert_equal [ [ :class, "W" ], [ :error, "Boom" ], [ :queue, "default" ] ], q.chips,
        "the chip strip must not reshuffle between renders"
    end

    def test_merge_and_without_are_immutable_and_explicit
      q = parse("class=A error=B stripe")
      assert_equal "A", q.merge(error: "C").klass
      assert_equal "C", q.merge(error: "C").error
      assert_nil q.without(:error).error
      assert_equal "A", q.without(:error).klass, "without must remove only what it names"
      assert_equal "stripe", q.without(:error).text
      assert_equal "", q.without(:text).text
      assert_equal "B", q.error, "the original must be untouched"
    end

    def test_any_and_any_facets_gate_the_right_things
      refute parse("").any?
      assert parse("stripe").any?
      refute parse("stripe").any_facets?, "text alone must not render a chip strip"
      assert parse("class=A").any_facets?
    end

    def test_equality_is_by_canonical_form
      assert_equal parse("class=A error=B"), parse("error=B class=A"),
        "the order typed must not change what the query IS"
      refute_equal parse("class=A"), parse("class=B")
    end

    def test_it_never_raises_on_anything
      [ nil, "", " ", "=", "==", "a=", "=a", %("), %(""), %(class="), "tag=", "text=",
        "a" * FilterQuery::MAX_LENGTH, "class=A=B", "class==A", "  class=A  ",
        "TEXT=A", "Class=A", "class=A tag=", "text=a text=b" ].each do |input|
        assert_kind_of FilterQuery, FilterQuery.parse(input), input.inspect
      end
    end
  end
end
