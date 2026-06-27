require "sidekiq"

module RoundhouseUi
  # Cooperative job cancellation — pure OSS, no preemption (Ruby can't safely
  # kill a running thread). Cancelled JIDs live in a Redis set:
  #
  #   * RoundhouseUi::CancelMiddleware skips a job whose JID is cancelled when it
  #     is *about* to run (covers queued/scheduled/retry jobs).
  #   * A long-running job can call RoundhouseUi.cancelled?(jid) and bail out.
  #
  # The set expires so stale flags clean themselves up.
  module Cancellation
    KEY = "roundhouse:cancelled"
    TTL = 86_400 # seconds

    module_function

    def cancel!(jid)
      Sidekiq.redis do |conn|
        conn.call("SADD", KEY, jid.to_s)
        conn.call("EXPIRE", KEY, TTL)
      end
    end

    def cancelled?(jid)
      Sidekiq.redis { |conn| conn.call("SISMEMBER", KEY, jid.to_s) } == 1
    end

    def clear!(jid)
      Sidekiq.redis { |conn| conn.call("SREM", KEY, jid.to_s) }
    end

    def cancelled_jids
      Sidekiq.redis { |conn| conn.call("SMEMBERS", KEY) }
    end
  end
end
