require "test_helper"

module RoundhouseUi
  # Every Rails test environment disables forgery protection, so no other test in
  # this suite has ever watched the guard run — which is how the README came to
  # promise "all destructive actions are CSRF-protected POSTs" while the engine
  # itself never asked for protection. This turns it back on.
  class ForgeryProtectionTest < ActionDispatch::IntegrationTest
    def setup
      @was_allowed = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      RoundhouseUi.read_only = false
    end

    def teardown
      ActionController::Base.allow_forgery_protection = @was_allowed
    end

    def test_a_destructive_post_without_a_token_is_refused
      post "/roundhouse/queues/default/pause"
      assert_equal 422, response.status,
        "a forged POST reached the action; a cross-site request can pause a queue"
    end

    # A source assertion, deliberately. The claim being pinned is not "forgery
    # protection is active in this app" — test above covers that, and it passes
    # either way because the dummy app's load_defaults puts the same guard on
    # ActionController::Base. The claim is "the engine declares its own", which is
    # what makes the README true for a host whose defaults predate 5.2.
    #
    # Behavioural approaches to that all require removing Base's guard mid-run,
    # and skip_forgery_protection there propagates into this subclass — so the
    # test would be asserting Rails' callback-inheritance semantics, in a
    # run-order-dependent way, rather than our declaration. The declaration IS
    # the subject here, so read it.
    def test_the_engine_declares_the_guard_rather_than_inheriting_it
      path, = Object.const_source_location("RoundhouseUi::ApplicationController")
      source = File.read(path)
      assert_match(/^\s*protect_from_forgery\s+with:\s+:exception\s*$/, source,
        "ApplicationController must ask for forgery protection itself; inheriting it " \
        "from the host's load_defaults leaves an app on older defaults unprotected")
    end

    def test_the_vendored_asset_stays_reachable
      # AssetsController opts out on purpose — it serves a static file and Rails'
      # cross-origin-JS guard would otherwise reject a plain <script src>.
      get "/roundhouse/turbo.js"
      assert_response :success
    end
  end
end
