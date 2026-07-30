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
    CHECK_EVERY = 2.0 # seconds — max staleness of the "nothing is cancelled" gate

    @gate = Mutex.new # guards @pending / @checked_at (see .pending?)

    module_function

    def cancel!(jid)
      Sidekiq.redis do |conn|
        conn.call("SADD", KEY, jid.to_s)
        conn.call("EXPIRE", KEY, TTL)
      end
      # Bust the local gate: the cancelling process sees its own cancel
      # immediately; other processes converge within CHECK_EVERY.
      @gate.synchronize do
        @pending = true
        @checked_at = monotonic_now
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

    # The middleware's hot-path gate: "is anything cancelled at all?" — almost
    # always no, so answering it with one EXISTS per process per CHECK_EVERY
    # (instead of a SISMEMBER per job) takes the common case to zero Redis
    # round-trips. While cancellations are pending, the middleware still does
    # the exact per-job SISMEMBER. A cancel issued by *another* process is
    # invisible here for up to CHECK_EVERY — acceptable because cancellation
    # is cooperative and racy by design (a job may already be running when the
    # flag lands), and cancel! busts the local gate so the cancelling process
    # itself is always exact.
    def pending?
      now = monotonic_now
      @gate.synchronize do
        if @checked_at.nil? || now - @checked_at >= CHECK_EVERY
          @pending = any?
          @checked_at = now
        end
        @pending
      end
    end

    def any?
      Sidekiq.redis { |conn| conn.call("EXISTS", KEY) } == 1
    end

    # Forget the cached gate state (tests; or after flushing Redis by hand).
    def reset_gate!
      @gate.synchronize do
        @pending = nil
        @checked_at = nil
      end
    end

    def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
