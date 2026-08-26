require_relative "../real_redis_test_case"

module RoundhouseUi
  # The dry run before a bulk delete rendered a 500 on Retries for months.
  #
  # bulk_preview draws job_path(set: @set) once per row, routes constrain set to
  # /dead|retry|scheduled/, and retries_controller passed "retries". It only fired
  # when at least one job MATCHED — an empty preview renders "Nothing to do" and
  # never reaches the row loop — so every existing test, which filtered to nothing
  # or asserted on the form alone, passed. The one page state an operator actually
  # sees before destroying jobs was the one state nothing rendered.
  #
  # Driven by a list, so adding a fourth set fails here until it has a preview.
  class RealRedisPreviewRendersTest < ActionDispatch::IntegrationTest
    self.fake_redis = false

    def setup
      skip "set ROUNDHOUSE_TEST_REDIS_URL" unless RealRedisTestCase::URL
      @forgery = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = false
      Sidekiq.configure_client { |c| c.redis = { url: RealRedisTestCase::URL } }
      Sidekiq.redis { |conn| conn.call("FLUSHDB") }
      RoundhouseUi.read_only = false
    end

    def teardown
      ActionController::Base.allow_forgery_protection = @forgery
    end

    SETS = [
      { path: "/roundhouse/dead/preview",      zset: "dead",     back: "/roundhouse/dead" },
      { path: "/roundhouse/retries/preview",   zset: "retry",    back: "/roundhouse/retries" }
    ].freeze

    def seed(zset, jid)
      Sidekiq.redis do |c|
        c.call("ZADD", zset, Time.now.to_f.to_s, Sidekiq.dump_json(
          "class" => "BillingWorker", "args" => [ "x" ], "queue" => "default",
          "jid" => jid, "retry_count" => 1, "error_class" => "Boom",
          "error_message" => "boom", "failed_at" => Time.now.to_f
        ))
      end
    end

    # The row loop is what breaks, so every case here must MATCH something.
    def test_the_dry_run_renders_with_rows_for_every_set
      SETS.each do |set|
        Sidekiq.redis { |c| c.call("FLUSHDB") }
        seed(set[:zset], "j1")

        get set[:path], params: { op: "delete", q: "class=BillingWorker" }

        assert_response :success, "#{set[:path]} did not render its own dry run"
        body = response.body.split("</style>").last.to_s
        assert_match(/\bj1\b/, body, "#{set[:path]} rendered no rows, so the row loop was never reached")
        # The row's job link has to be a URL the router will actually accept.
        assert_match %r{href="[^"]*/(?:dead|retry|scheduled)/j1}, body,
          "#{set[:path]} built a job link with a set key the routes reject"
      end
    end

    # The same page with a WILDCARD, since that is now how an operator scopes a
    # family before deleting it.
    def test_the_dry_run_renders_under_a_wildcard
      SETS.each do |set|
        Sidekiq.redis { |c| c.call("FLUSHDB") }
        seed(set[:zset], "j1")

        get set[:path], params: { op: "delete", q: "class=Billing%" }

        assert_response :success, "#{set[:path]} 500'd on a wildcard dry run"
        assert_match(/\bj1\b/, response.body.split("</style>").last.to_s)
      end
    end

    # And the empty case still has to be honest rather than 500 or celebratory.
    def test_an_empty_dry_run_says_nothing_matches
      SETS.each do |set|
        Sidekiq.redis { |c| c.call("FLUSHDB") }
        seed(set[:zset], "j1")

        get set[:path], params: { op: "delete", q: "class=NoSuchWorker" }

        assert_response :success
        assert_match(/Nothing matches/i, response.body)
      end
    end
  end
end
