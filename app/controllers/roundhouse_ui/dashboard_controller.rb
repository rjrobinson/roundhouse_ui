module RoundhouseUi
  # The dashboard reads straight from Sidekiq's API — no database, no models.
  # Everything here comes out of Redis via Sidekiq::Stats / Sidekiq::Queue.
  class DashboardController < ApplicationController
    def show
      @stats  = Sidekiq::Stats.new
      @queues = Sidekiq::Queue.all
      @metrics = Metrics.new(stats: @stats)
      @health  = Health.new(stats: @stats, queues: @queues, metrics: @metrics)
      # Highest-signal slices for the overview, from data we already read.
      @top_errors = ErrorGroups.new(limit: 200).call.groups.first(5)
      @problem_queues = @queues.select { |q| q.latency > 5 }.sort_by { |q| -q.latency }.first(5)
    end

    # Polled by the dashboard for live counts (same approach Sidekiq Web uses —
    # cheap JSON, no WebSocket/build step required).
    def stats
      s = Sidekiq::Stats.new
      render json: {
        processed: s.processed,
        failed:    s.failed,
        enqueued:  s.enqueued,
        busy:      s.workers_size,
        scheduled: s.scheduled_size,
        retries:   s.retry_size,
        dead:      s.dead_size,
        queues:    Sidekiq::Queue.all.size
      }
    end
  end
end
