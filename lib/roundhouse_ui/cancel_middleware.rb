require "roundhouse_ui/cancellation"

module RoundhouseUi
  # Opt-in Sidekiq server middleware that drops a job whose JID was cancelled
  # before it runs. Install it:
  #
  #   Sidekiq.configure_server do |config|
  #     config.server_middleware { |chain| chain.add RoundhouseUi::CancelMiddleware }
  #   end
  #
  # Hot-path cost: near zero. Cancellation.pending? answers "anything cancelled
  # at all?" from a process-local gate (one EXISTS per CHECK_EVERY seconds, not
  # per job); the exact per-job SISMEMBER only runs while cancellations are
  # actually pending. State lives on the Cancellation module because Sidekiq
  # builds a fresh middleware instance per job — ivars here wouldn't survive.
  class CancelMiddleware
    def call(_worker, job, _queue)
      if RoundhouseUi::Cancellation.pending? && RoundhouseUi::Cancellation.cancelled?(job["jid"])
        RoundhouseUi::Cancellation.clear!(job["jid"])
        return # acknowledge without running
      end
      yield
    end
  end
end
