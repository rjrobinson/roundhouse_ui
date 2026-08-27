require_relative "../real_redis_test_case"

module RoundhouseUi
  # The search box is untrusted input that scopes a destructive action, so it gets
  # the same scrutiny as anything else that does.
  class RealRedisSearchSafetyTest < ActionDispatch::IntegrationTest
    self.fake_redis = false

    SECRET = "sk_live_SECRET42".freeze
    # Longer than the cap, so a substring of it can be over the limit and still be
    # something that genuinely exists in the data.
    LONG_VALUE = ("needle" * 200).freeze

    def setup
      skip "set ROUNDHOUSE_TEST_REDIS_URL" unless RealRedisTestCase::URL
      @forgery = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = false
      Sidekiq.configure_client { |c| c.redis = { url: RealRedisTestCase::URL } }
      Sidekiq.redis { |conn| conn.call("FLUSHDB") }
      RoundhouseUi.read_only = false
      @previous_redaction = RoundhouseUi.redact_args
      RoundhouseUi.redact_args = %w[token password secret]
      seed
    end

    def teardown
      ActionController::Base.allow_forgery_protection = @forgery
      RoundhouseUi.redact_args = @previous_redaction
      Sidekiq.redis { |conn| conn.call("FLUSHDB") } if RealRedisTestCase::URL
    end

    def seed
      Sidekiq.redis do |conn|
        conn.call("ZADD", "dead", "0", Sidekiq.dump_json(
          "class" => "Billing::ChargeWorker", "queue" => "stripe", "jid" => "victim",
          "args" => [ { "account_id" => 7, "api_token" => SECRET } ],
          "error_class" => "Stripe::CardError", "failed_at" => Time.now.to_f))
        conn.call("ZADD", "dead", "1", Sidekiq.dump_json(
          "class" => "Mailer::SendWorker", "queue" => "mailers", "jid" => "other",
          "args" => [ { "account_id" => 8, "template" => "welcome" } ],
          "error_class" => "Net::SMTPError", "failed_at" => Time.now.to_f))
        # An entry a long needle WOULD match, so "refused" can be told apart from
        # "matched nothing". Without it a 501-character needle finds nothing either
        # way and the guard is untestable.
        conn.call("ZADD", "dead", "2", Sidekiq.dump_json(
          "class" => "Bulk::ImportWorker", "queue" => "default", "jid" => "haystack",
          "args" => [ { "note" => LONG_VALUE } ],
          "error_class" => "ArgumentError", "failed_at" => Time.now.to_f))
      end
    end

    def markup = response.body.split("</style>").last.to_s

    # The table body only. Asserting against the whole page is wrong: the layout
    # ships inline JS, so a short word like "other" matches a comment in it and a
    # refute can never pass.
    def rows = markup[/<tbody>.*?<\/tbody>/m].to_s

    def jids
      rows.scan(/aria-label="select ([^"]+)"/).flatten - [ "all" ]
    end

    def found?(q)
      get "/roundhouse/dead", params: { q: q }
      jids.include?("victim")
    end

    # ── the oracle ────────────────────────────────────────────────────────────
    def test_a_redacted_value_cannot_be_confirmed_through_search
      # Every prefix used to match, and a wrong character did not — so the box
      # answered "is this the secret?" one character at a time. The UI has never
      # displayed the value; search must not either.
      leaks = [ SECRET, SECRET[0, 12], SECRET[0, 10], "sk_live_S", "SECRET42" ]
                .select { |needle| found?(needle) }

      assert_empty leaks,
        "search confirmed #{leaks.size} substring(s) of a value the UI masks: " \
        "#{leaks.inspect}. That is an oracle — a token can be read out a character " \
        "at a time by someone who can see the console and not the secrets."
    end

    def test_a_non_secret_argument_is_still_searchable
      # The fix must not make arguments unsearchable; only the masked ones.
      assert found?("account_id"), "argument keys stopped being searchable"
      get "/roundhouse/dead", params: { q: "welcome" }
      assert_includes jids, "other", "an unredacted argument value stopped matching"
    end

    def test_redaction_off_leaves_search_unchanged
      RoundhouseUi.redact_args = []
      assert found?(SECRET),
        "with nothing configured for redaction, arguments must search exactly as before"
    end

    def test_the_oracle_is_closed_on_the_bulk_path_too
      # The same needle scoped a dry run and a delete, so the oracle worked through
      # the confirm screen as well as the list.
      get "/roundhouse/dead/preview", params: { op: "delete", q: SECRET }
      refute_match(/aria-label="select victim"|>victim</, rows,
        "the dry run confirmed the secret")
    end

    # ── the needle as a resource ───────────────────────────────────────────────
    def test_an_over_long_needle_is_refused_even_when_it_would_have_matched
      # The distinction that matters. A needle over the cap that matches NOTHING
      # proves nothing — it would find nothing either way. This one is a real
      # substring of a real argument, so a scan would return the row and a refusal
      # will not.
      over = LONG_VALUE[0, JobSetBrowsing::MAX_QUERY_LENGTH + 1]
      assert_operator over.length, :>, JobSetBrowsing::MAX_QUERY_LENGTH

      get "/roundhouse/dead", params: { q: over }
      assert_response :success
      assert_empty jids,
        "an over-long needle was scanned rather than refused — the scan is linear in " \
        "needle length times entry count, so this is free CPU on someone else's box"
    end

    def test_just_under_the_cap_still_matches_what_it_should
      # The cap must reject only what is over it, or it is a silent search bug.
      under = LONG_VALUE[0, JobSetBrowsing::MAX_QUERY_LENGTH]
      get "/roundhouse/dead", params: { q: under }

      assert_includes jids, "haystack",
        "a needle at exactly the cap stopped matching a value that contains it"
    end

    def test_a_refused_needle_cannot_authorise_a_bulk_action
      # Refused must mean "no filter", not "a filter that matches everything" —
      # otherwise an over-long q becomes a way to delete the set.
      before = Sidekiq::DeadSet.new.size
      # A needle that WOULD match, so this is a refusal and not a miss.
      long = LONG_VALUE[0, JobSetBrowsing::MAX_QUERY_LENGTH + 1]
      post "/roundhouse/dead/bulk_all", params: { op: "delete", q: long }

      assert_equal before, Sidekiq::DeadSet.new.size,
        "an over-long query authorised a bulk delete"
      # The refusal names its own reason now. Asserted as a property rather than a
      # literal: what matters is that the operator is told a destroy was declined
      # AND why, not that the sentence still reads "needs a filter" — which was the
      # no-filter-at-all wording and was misleading for a refused one.
      alert = flash[:alert].to_s
      assert_match(/^Refused/, alert, "a declined destroy must say so first")
      assert_match(/too long/, alert, "and must name the reason the operator can act on")
    end
  end
end
