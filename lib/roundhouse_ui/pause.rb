require "set"
require "sidekiq"

module RoundhouseUi
  # Roundhouse's own queue-pause registry — pure OSS, no Sidekiq Pro.
  #
  # Paused queue names live in a Redis set. RoundhouseUi::Fetch consults this set
  # and skips paused queues when pulling work, so a paused queue stops being
  # consumed without stopping the worker process.
  #
  # When Sidekiq Pro is loaded we defer to *its* registry instead (see .native?).
  # Under Pro we defer to its own pause API (see .native?), so pausing is enforced
  # with no Roundhouse fetcher installed. Pro's key is not ours.
  module Pause
    KEY        = "roundhouse:paused"
    FETCH_FLAG = "roundhouse:fetch_alive" # liveness beacon set by the fetcher
    PRO_KEY    = "paused" # Sidekiq Pro's own registry

    module_function

    # True when Sidekiq Pro's queue-pause API is available. Feature-detected on
    # the method rather than `defined?(Sidekiq::Pro)` so it tracks the actual
    # capability across Pro versions. Cheap (no Redis), so it isn't memoized —
    # loading Pro mid-process would otherwise be missed.
    def native?
      defined?(::Sidekiq::Queue) && ::Sidekiq::Queue.method_defined?(:pause!)
    end

    # Under Pro, always go through Sidekiq::Queue#pause! — writing PRO_KEY directly
    # does not reach already-running workers.
    def pause!(queue)
      return ::Sidekiq::Queue.new(queue.to_s).pause! if native?

      Sidekiq.redis { |conn| conn.call("SADD", KEY, queue.to_s) }
    end

    def unpause!(queue)
      return ::Sidekiq::Queue.new(queue.to_s).unpause! if native?

      Sidekiq.redis { |conn| conn.call("SREM", KEY, queue.to_s) }
    end

    def paused?(queue)
      Sidekiq.redis { |conn| conn.call("SISMEMBER", key, queue.to_s) } == 1
    end

    def paused_queues
      Sidekiq.redis { |conn| conn.call("SMEMBERS", key) }.sort
    end

    def paused_set
      Set.new(Sidekiq.redis { |conn| conn.call("SMEMBERS", key) })
    end

    # Which registry reads come from. Reads are plain set lookups in both cases
    # (no pubsub involved), so they can share one implementation.
    def key
      native? ? PRO_KEY : KEY
    end

    # Given the redis queue keys BasicFetch would poll (e.g. "queue:default"),
    # drop any whose queue is paused. Pure given the paused set, so it's unit
    # testable without a running Sidekiq.
    def reject_paused(queue_keys)
      paused = paused_set
      return queue_keys if paused.empty?

      queue_keys.reject { |key| paused.include?(key.to_s.delete_prefix("queue:")) }
    end

    # The fetcher calls this periodically so the web UI can tell whether pausing
    # is actually enforced (the worker and web run in separate processes). The
    # short TTL means the flag disappears soon after all Roundhouse fetchers stop.
    def mark_fetch_alive!(ttl = 30)
      Sidekiq.redis { |conn| conn.call("SET", FETCH_FLAG, "1", "EX", ttl) }
    end

    # True when a RoundhouseUi::Fetch has reported in recently — i.e. pausing
    # will take effect. When false, the UI warns instead of pretending.
    #
    # Under Pro no beacon is needed: any Pro worker enforces pauses whether or not
    # our fetcher is installed.
    def fetch_installed?
      return true if native?

      Sidekiq.redis { |conn| conn.call("EXISTS", FETCH_FLAG) } == 1
    end
  end
end
