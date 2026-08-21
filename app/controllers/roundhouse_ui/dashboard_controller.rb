module RoundhouseUi
  # The dashboard reads straight from Sidekiq's API — no database, no models.
  # Everything here comes out of Redis via Sidekiq::Stats / Sidekiq::Queue.
  class DashboardController < ApplicationController
    def show
      @stats  = backend.stats
      @queues = backend.queues
      @metrics = Metrics.new(stats: @stats)
      @health  = Health.new(stats: @stats, queues: @queues, metrics: @metrics)
      # Highest-signal slices for the overview, from data we already read.
      @top_errors = ErrorGroups.new(limit: 200).call.groups.first(5)
      @problem_queues = @queues.select { |q| q.latency > 5 }.sort_by { |q| -q.latency }.first(5)
    end

    # Polled by the dashboard for live counts (same approach Sidekiq Web uses —
    # cheap JSON, no WebSocket/build step required).
    def stats
      s = backend.stats
      # queues was already loaded here for the count, so the names ride along
      # free — the command palette uses them to tell a queue name from a plain
      # search term without adding a Redis call to every page render.
      # queue_summaries, not queues: Sidekiq::Queue#size issues its own LLEN, so
      # reading a depth per queue off `queues` would put one round-trip per queue
      # on the endpoint every open tab hits every few seconds — the same N+1 that
      # was removed from the Queues page. This is two round-trips at any queue count.
      qs = backend.queue_summaries
      render json: {
        processed: s.processed,
        failed:    s.failed,
        enqueued:  s.enqueued,
        busy:      s.workers_size,
        scheduled: s.scheduled_size,
        retries:   s.retry_size,
        dead:      s.dead_size,
        queues:      qs.size,
        queue_names: qs.map(&:name).sort,
        # The drain forecast needs a second sample to compute a velocity, and
        # this is the read that already has the depths.
        queue_depths: qs.to_h { |q| [ q.name, q.size ] }
      }
    end
  end
end
