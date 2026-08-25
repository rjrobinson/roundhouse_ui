require "test_helper"

module RoundhouseUi
  # read_only used to be seven copies of the same guard, each wired to its own
  # hand-maintained `only:` list, and only three of the seven had any test at all.
  # These cover the property rather than the copies.
  class ReadOnlyTest < ActionDispatch::IntegrationTest
    def teardown = RoundhouseUi.read_only = false

    # Every POST the engine routes, and which controller action it lands on.
    def mutating_routes
      Engine.routes.routes.filter_map do |route|
        next unless route.verb == "POST"

        controller, action = route.defaults.values_at(:controller, :action)
        [ controller, action ]
      end.uniq
    end

    def test_no_mutating_route_is_unguarded_by_accident
      exempt = mutating_routes.select do |controller, action|
        "#{controller}_controller".camelize.constantize.read_only_exempt_actions.include?(action)
      end

      assert_equal [ [ "roundhouse_ui/queues", "snapshot" ] ], exempt,
        "a POST is exempt from read-only enforcement. Taking a snapshot is the one " \
        "deliberate exemption (it writes nothing an operator can lose). Anything " \
        "else here is a destructive action someone opted out of — justify it or drop it."
    end

    def test_a_fresh_controller_inherits_no_exemptions
      # The whole point of fail-closed: a controller that says nothing is guarded.
      assert_empty ApplicationController.read_only_exempt_actions
      assert_empty ApplicationController.read_only_extra_actions
    end

    def test_read_only_refuses_a_write_on_a_section_that_never_had_a_test
      RoundhouseUi.read_only = true
      post "/roundhouse/workers/quiet", params: { identity: "host:1:abc" }
      assert_redirected_to "/roundhouse/workers"
      assert_equal "Roundhouse is in read-only mode — this action is disabled.", flash[:alert]
    end

    def test_read_only_refuses_a_scheduled_delete
      RoundhouseUi.read_only = true
      post "/roundhouse/scheduled/abc123/delete"
      assert_redirected_to "/roundhouse/scheduled"
    end

    def test_read_only_refuses_a_dry_run_that_previews_a_bulk_action
      # A preview is a GET, so the POST rule alone would let it through. It shows
      # what a bulk delete would touch, and is gated with the action it previews.
      RoundhouseUi.read_only = true
      get "/roundhouse/dead/preview", params: { q: "x", op: "delete" }
      assert_redirected_to "/roundhouse/dead"
    end

    def test_taking_a_snapshot_still_works_in_read_only_mode
      RoundhouseUi.read_only = true
      post "/roundhouse/queues/default/snapshot"
      assert_redirected_to "/roundhouse/queues"
      assert_match(/Snapshot saved/, flash[:notice],
        "the one deliberate exemption stopped working")
    end

    def test_reads_are_untouched
      RoundhouseUi.read_only = true
      get "/roundhouse/queues"
      assert_response :success
    end
  end
end
