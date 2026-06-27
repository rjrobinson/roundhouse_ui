require "test_helper"

module RoundhouseUi
  class AuditTest < ActionDispatch::IntegrationTest
    def teardown = RoundhouseUi.read_only = false

    def test_record_and_recent_roundtrip
      with_fake_redis do
        Audit.record(actor: "rj@trainual.com", action: "purged queue", target: "low")
        entry = Audit.recent.first
        assert_equal "rj@trainual.com", entry["actor"]
        assert_equal "purged queue", entry["action"]
        assert_equal "low", entry["target"]
      end
    end

    def test_a_state_changing_request_is_audited
      with_fake_redis do
        post "/roundhouse/queues/low/pause"
        entry = Audit.recent.first
        assert_equal "paused queue", entry["action"]
        assert_equal "low", entry["target"]
        assert_equal "anonymous", entry["actor"]
      end
    end

    def test_actor_resolver_attributes_the_action
      RoundhouseUi.actor_resolver = ->(_controller) { "mara@trainual.com" }
      with_fake_redis do
        post "/roundhouse/queues/low/pause"
        assert_equal "mara@trainual.com", Audit.recent.first["actor"]
      end
    ensure
      RoundhouseUi.actor_resolver = nil
    end

    def test_read_only_actions_are_not_audited
      RoundhouseUi.read_only = true
      with_fake_redis do
        post "/roundhouse/queues/low/pause" # halted by before_action → no audit
        assert_empty Audit.recent
      end
    end
  end
end
