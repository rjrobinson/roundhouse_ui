require_relative "../real_redis_test_case"

module RoundhouseUi
  # `bulk_all` acts on every job matching the current filter. With NO filter, every
  # job matches: entry_selected? finds nothing to fail, `"".present?` is false, and
  # `return true if tag.nil?` does the rest.
  #
  # So POST /roundhouse/dead/bulk_all with nothing but op=delete emptied the set up
  # to the 1,000 cap and reported "Deleted 50 matching job(s)" as though that were
  # the request. Confirmed against a real Redis before the guard existed.
  #
  # The comment above the action said it was "only offered when a filter is active".
  # It was only OFFERED that way — the view hid the button, the route stayed open.
  class RealRedisUnfilteredBulkTest < ActionDispatch::IntegrationTest
    self.fake_redis = false

    def setup
      skip "set ROUNDHOUSE_TEST_REDIS_URL" unless RealRedisTestCase::URL
      @forgery = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = false
      Sidekiq.configure_client { |c| c.redis = { url: RealRedisTestCase::URL } }
      Sidekiq.redis { |conn| conn.call("FLUSHDB") }
      RoundhouseUi.read_only = false
      seed
    end

    def teardown
      ActionController::Base.allow_forgery_protection = @forgery
      Sidekiq.redis { |conn| conn.call("FLUSHDB") } if RealRedisTestCase::URL
    end

    def seed
      %w[dead retry].each do |set|
        20.times do |i|
          Sidekiq.redis do |conn|
            conn.call("ZADD", set, i.to_s, Sidekiq.dump_json(
              "class" => "W#{i % 4}", "args" => [], "queue" => "default", "jid" => "#{set}#{i}",
              "error_class" => "Boom", "retry_count" => 1, "failed_at" => Time.now.to_f
            ))
          end
        end
      end
    end

    def test_an_unfiltered_bulk_delete_on_the_dead_set_is_refused
      post "/roundhouse/dead/bulk_all", params: { op: "delete" }

      assert_equal 20, Sidekiq::DeadSet.new.size,
        "an unfiltered bulk_all destroyed the set — every entry matches when nothing filters"
      assert_match(/needs a filter/i, flash[:alert].to_s,
        "it must say why it refused, not report deleting nothing")
    end

    def test_an_unfiltered_bulk_retry_on_the_retry_set_is_refused
      post "/roundhouse/retries/bulk_all", params: { op: "retry" }

      assert_equal 20, Sidekiq::RetrySet.new.size
      assert_match(/needs a filter/i, flash[:alert].to_s)
    end

    def test_the_dry_run_refuses_too
      # The preview's confirm button posts to bulk_all. A dry run that lists the
      # whole set is an invitation to confirm exactly the thing being prevented.
      get "/roundhouse/dead/preview", params: { op: "delete" }

      assert_response :success
      body = response.body.split("</style>").last.to_s
      refute_match(/dead0/, body, "the dry run listed the entire unfiltered set")
    end

    def test_a_filtered_bulk_delete_still_works
      # The guard must not break the feature it protects.
      post "/roundhouse/dead/bulk_all", params: { op: "delete", q: "W1" }

      remaining = Sidekiq::DeadSet.new.map { |e| e.klass }
      assert_equal 15, remaining.size, "a filtered bulk delete stopped working"
      refute_includes remaining, "W1"
    end

    def test_the_checkbox_bulk_still_works_without_a_filter
      # `bulk` carries an explicit list of jids. That IS its scope, so it must not
      # be caught by the guard — the two actions are different in exactly this way.
      post "/roundhouse/dead/bulk", params: { op: "delete", jids: %w[dead0 dead1] }

      assert_equal 18, Sidekiq::DeadSet.new.size,
        "the checkbox bulk was broken by a guard meant for the filter-scoped one"
    end

    def test_the_view_and_the_route_agree_on_what_counts_as_a_filter
      # They disagreed: any_filter? gated the button while the route gated nothing.
      # The helper now delegates to the concern's predicate, so there is one answer.
      get "/roundhouse/dead"
      body = response.body.split("</style>").last.to_s
      refute_match(/bulk_all/, body, "the unfiltered page offers a bulk-all control")

      get "/roundhouse/dead", params: { q: "W1" }
      body = response.body.split("</style>").last.to_s
      assert_match(/preview/, body, "a filtered page must offer the bulk controls")
    end
    # THE property the dry run exists to provide, asserted end to end with real
    # deletes: whatever the preview counted is what the confirm destroys.
    #
    # It did not hold. The confirm form carried op, q, tag and queue — not class or
    # error — so a preview listing 2 jobs POSTed a request that deleted 5, and
    # reported "Deleted 5 matching job(s)" as though that had been approved.
    def test_the_dry_run_count_is_exactly_what_the_confirm_destroys
      Sidekiq.redis { |c| c.call("FLUSHDB") }
      [ %w[a1 BillingWorker stripe], %w[a2 BillingWorker stripe],
        %w[c1 MailerWorker stripe], %w[c2 MailerWorker stripe],
        %w[d1 SearchWorker stripe] ].each_with_index do |(jid, klass, arg), i|
        Sidekiq.redis { |c| c.call("ZADD", "dead", i.to_s, Sidekiq.dump_json(
          "class" => klass, "args" => [ arg ], "queue" => "default", "jid" => jid,
          "error_class" => "Boom", "failed_at" => Time.now.to_f)) }
      end

      # A query that matches all five, AND a class filter that narrows to two.
      get "/roundhouse/dead/preview", params: { op: "delete", q: "stripe", class: "BillingWorker" }
      assert_response :success

      body = response.body.split("</style>").last.to_s
      previewed = body.scan(/\b(?:a1|a2|c1|c2|d1)\b/).uniq
      assert_equal %w[a1 a2], previewed.sort, "the dry run did not honour the class filter"

      form = body[/<form[^>]*bulk_all[^>]*>.*?<\/form>/m] ||
             body[/<form(?:(?!<\/form>).)*bulk_all(?:(?!<\/form>).)*<\/form>/m]
      refute_nil form, "no confirm form in the dry run"
      params = form.scan(/<input[^>]*name="([^"]+)"[^>]*value="([^"]*)"/).to_h
      assert_equal "BillingWorker", params["class"],
        "the confirm form dropped the class filter, so it will delete more than was shown"

      post "/roundhouse/dead/bulk_all", params: params
      survivors = Sidekiq::DeadSet.new.map(&:jid).sort

      assert_equal %w[c1 c2 d1], survivors,
        "confirmed a deletion of #{previewed.size} and destroyed #{5 - survivors.size}"
      assert_match(/Deleted 2 /, flash[:notice].to_s,
        "the notice must report what was approved")
    end
  end
end
