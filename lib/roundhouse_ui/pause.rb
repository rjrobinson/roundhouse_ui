require "set"
require "sidekiq"

module RoundhouseUi
  # Roundhouse's own queue-pause registry — pure OSS, no Sidekiq Pro.
  #
  # Paused queue names live in a Redis set. RoundhouseUi::Fetch consults this set
  # and skips paused queues when pulling work, so a paused queue stops being
  # consumed without stopping the worker process.
  module Pause
    KEY        = "roundhouse:paused"
    FETCH_FLAG = "roundhouse:fetch_alive" # liveness beacon set by the fetcher

    module_function

    def pause!(queue)
      Sidekiq.redis { |conn| conn.call("SADD", KEY, queue.to_s) }
    end

    def unpause!(queue)
      Sidekiq.redis { |conn| conn.call("SREM", KEY, queue.to_s) }
    end

    def paused?(queue)
      Sidekiq.redis { |conn| conn.call("SISMEMBER", KEY, queue.to_s) } == 1
    end

    def paused_queues
      Sidekiq.redis { |conn| conn.call("SMEMBERS", KEY) }.sort
    end

    def paused_set
      Set.new(Sidekiq.redis { |conn| conn.call("SMEMBERS", KEY) })
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
    def fetch_installed?
      Sidekiq.redis { |conn| conn.call("EXISTS", FETCH_FLAG) } == 1
    end
  end
end
