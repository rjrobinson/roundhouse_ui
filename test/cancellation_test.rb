require "test_helper"

module RoundhouseUi
  class CancellationTest < ActiveSupport::TestCase
    def test_cancel_check_clear_roundtrip
      with_fake_redis do
        refute Cancellation.cancelled?("j1")
        Cancellation.cancel!("j1")
        assert Cancellation.cancelled?("j1")
        assert RoundhouseUi.cancelled?("j1") # convenience delegate
        Cancellation.clear!("j1")
        refute Cancellation.cancelled?("j1")
      end
    end

    def test_middleware_skips_a_cancelled_job
      with_fake_redis do
        Cancellation.cancel!("j1")
        ran = false
        CancelMiddleware.new.call(nil, { "jid" => "j1" }, "default") { ran = true }
        refute ran, "cancelled job is skipped"
        refute Cancellation.cancelled?("j1"), "flag is cleared after skipping"
      end
    end

    def test_middleware_runs_a_normal_job
      with_fake_redis do
        ran = false
        CancelMiddleware.new.call(nil, { "jid" => "j2" }, "default") { ran = true }
        assert ran
      end
    end
  end
end
