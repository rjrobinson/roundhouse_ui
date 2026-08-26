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
      "class=Bill*"        => /Wildcards are not supported in class=/,
      "error=Time?ut"      => /Wildcards are not supported in error=/,
      %(text="a" trailing) => /Text is given twice/
    }.freeze

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
      assert_nil parse("tag=nocolon").tag_pair, "a tag with no colon has no pair to match on"
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
