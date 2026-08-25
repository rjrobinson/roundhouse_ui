require_relative "../real_redis_test_case"

module RoundhouseUi
  # Every bulk action on the Dead set failed with InvalidAuthenticityToken while
  # submitting a token that looked perfectly valid.
  #
  # The bulk form wrapped the table, so each row's button_to form was nested
  # inside it. Nested forms are invalid HTML — the parser closes the outer form at
  # the first </form> — so the bulk form ended up containing a row action's
  # authenticity_token as well as its own. Rails takes the last of a duplicated
  # parameter, which meant verifying a per-form token minted for /dead/:jid/retry
  # against a POST to /dead/bulk.
  #
  # Needs a real Redis: the in-memory stand-in cannot serve DeadSet#each, so the
  # table renders empty and none of this markup exists to inspect.
  class RealRedisBulkFormTest < ActionDispatch::IntegrationTest
    self.fake_redis = false

    INDEX_PATHS = %w[
      /roundhouse/dead /roundhouse/retries /roundhouse/scheduled
      /roundhouse/queues /roundhouse/busy /roundhouse/workers /roundhouse/errors
    ].freeze

    def setup
      skip "set ROUNDHOUSE_TEST_REDIS_URL" unless RealRedisTestCase::URL
      @forgery = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
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
      3.times do |i|
        payload = Sidekiq.dump_json(
          "class" => "W", "args" => [], "queue" => "default", "jid" => "j#{i}",
          "error_class" => "Boom", "failed_at" => Time.now.to_f, "retry_count" => 1
        )
        Sidekiq.redis do |conn|
          conn.call("ZADD", "dead", i.to_s, payload)
          conn.call("ZADD", "retry", i.to_s, payload)
          conn.call("ZADD", "schedule", i.to_s, payload)
        end
      end
    end

    def markup = response.body.split("</style>").last.to_s

    # Depth in document order. A well-formed page never opens a second form
    # before closing the first.
    def max_form_depth(html)
      depth = 0
      html.scan(/<form\b|<\/form>/).reduce(0) do |peak, tag|
        depth += tag.start_with?("</") ? -1 : 1
        [ peak, depth ].max
      end
    end

    def test_no_index_view_nests_a_form
      INDEX_PATHS.each do |path|
        get path
        assert_response :success, "#{path} did not render"
        assert_operator max_form_depth(markup), :<=, 1,
          "#{path} nests a <form> (depth #{max_form_depth(markup)}). The parser " \
          "closes the outer one at the first </form>, so its inputs — including the " \
          "CSRF token — end up in the wrong form. Associate controls with " \
          "form=\"id\" instead of wrapping them."
      end
    end

    def test_the_bulk_form_carries_exactly_one_token
      get "/roundhouse/dead"
      assert_match 'name="jids[]"', markup, "expected rows with checkboxes"

      open_at = markup.index('id="rh-bulk-dead"')
      refute_nil open_at, "the bulk form is gone"
      close_at = markup.index("</form>", open_at)
      span = markup[open_at...close_at]

      assert_equal 1, span.scan(/name="authenticity_token"/).size,
        "the bulk form contains more than one CSRF token; Rails verifies the last " \
        "one, which will be scoped to some other action's path"
      assert_equal 0, span.scan(/<form\b/).size, "another form opens inside the bulk form"
    end

    def test_the_checkboxes_belong_to_the_bulk_form
      get "/roundhouse/dead"
      checkboxes = markup.scan(/<input[^>]*name="jids\[\]"[^>]*>/)

      refute_empty checkboxes
      checkboxes.each do |cb|
        assert_match(/form="rh-bulk-dead"/, cb,
          "a checkbox is outside the form and not associated with it, so its jid " \
          "is silently dropped from the submission")
      end
    end

    def test_a_bulk_delete_verifies_and_deletes
      get "/roundhouse/dead"
      open_at = markup.index('id="rh-bulk-dead"')
      span = markup[open_at...markup.index("</form>", open_at)]
      # The LAST one, because that is the one that decides the outcome. A browser
      # submits every token the form contains, duplicate parameters collapse, and
      # Rails keeps the last. Taking the first here is what made an earlier version
      # of this test pass against the very bug it was written to catch.
      token = span.scan(/name="authenticity_token" value="([^"]*)"/).flatten.last
      refute_nil token, "no token in the bulk form"

      post "/roundhouse/dead/bulk",
           params: { authenticity_token: token, op: "delete", jids: %w[j0 j1] }

      refute_equal 422, response.status,
        "the bulk form's own token was rejected — #{response.status}"
      assert_equal 1, Sidekiq::DeadSet.new.size, "the bulk delete did not take"
    end
  end
end
