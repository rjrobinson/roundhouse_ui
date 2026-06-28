require "sidekiq/api"

module RoundhouseUi
  # Derived, single-snapshot metrics computed from data we already read
  # (Sidekiq::Stats + the live ProcessSet). No storage and no deltas — these are
  # instantaneous. Rate-based metrics (jobs/sec, velocity) are computed
  # client-side from the dashboard's poll stream; per-class durations need the
  # collector (a separate, opt-in piece).
  class Metrics
    def initialize(stats: Sidekiq::Stats.new, processes: Sidekiq::ProcessSet.new)
      @stats = stats
      @processes = processes
    end

    # Total worker threads across the live fleet.
    def concurrency
      @concurrency ||= @processes.sum { |process| process["concurrency"].to_i }
    end

    # Worker threads currently running a job.
    def busy
      @stats.workers_size
    end

    # Fraction of worker threads in use (0.0–1.0), or nil when no capacity is
    # reporting in (no processes up) — so the view can show "—" instead of 0%.
    def utilization
      return nil if concurrency.zero?

      busy.to_f / concurrency
    end

    # Idle worker threads.
    def headroom
      [ concurrency - busy, 0 ].max
    end

    # Everything waiting to run: live queues + scheduled + retrying.
    def backlog
      @stats.enqueued + @stats.scheduled_size + @stats.retry_size
    end

    # Share of processed jobs that failed, lifetime. Coarse (Sidekiq keeps only
    # cumulative counters); the live failure rate is computed client-side.
    def failure_ratio
      return 0.0 if @stats.processed.zero?

      @stats.failed.to_f / @stats.processed
    end
  end
end
