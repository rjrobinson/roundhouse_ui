require "roundhouse_ui/cancellation"

module RoundhouseUi
  # Opt-in Sidekiq server middleware that drops a job whose JID was cancelled
  # before it runs. Install it:
  #
  #   Sidekiq.configure_server do |config|
  #     config.server_middleware { |chain| chain.add RoundhouseUi::CancelMiddleware }
  #   end
  class CancelMiddleware
    def call(_worker, job, _queue)
      if RoundhouseUi::Cancellation.cancelled?(job["jid"])
        RoundhouseUi::Cancellation.clear!(job["jid"])
        return # acknowledge without running
      end
      yield
    end
  end
end
