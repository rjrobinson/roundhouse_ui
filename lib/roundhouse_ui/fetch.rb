require "sidekiq/fetch"
require "roundhouse_ui/pause"

module RoundhouseUi
  # Opt-in fetch strategy that honors RoundhouseUi::Pause. Install it server-side:
  #
  #   # config/initializers/sidekiq.rb
  #   Sidekiq.configure_server do |config|
  #     config[:fetch_class] = RoundhouseUi::Fetch
  #   end
  #
  # Until this fetcher is active, pausing a queue has no effect — the UI detects
  # that (via the liveness beacon below) and warns rather than pretending.
  #
  # Inherits all of BasicFetch's behavior (weights, strict ordering, timeouts);
  # we only filter the queue list. BasicFetch#retrieve_work already handles an
  # empty list (sleep + return), so "all queues paused" is safe.
  class Fetch < Sidekiq::BasicFetch
    BEACON_INTERVAL = 5 # seconds; throttles the liveness write

    def queues_cmd
      touch_liveness
      RoundhouseUi::Pause.reject_paused(super)
    end

    private

    def touch_liveness
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @rh_beat_at && (now - @rh_beat_at) < BEACON_INTERVAL

      @rh_beat_at = now
      RoundhouseUi::Pause.mark_fetch_alive!
    end
  end
end
