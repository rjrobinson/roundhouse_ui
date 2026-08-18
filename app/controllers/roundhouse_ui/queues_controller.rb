module RoundhouseUi
  class QueuesController < ApplicationController
    before_action :require_writable!, only: %i[purge pause resume]

    def index
      @query = params[:q].to_s.strip
      # queue_summaries reads depth and latency for every queue in one batch.
      # Mapping over backend.queues instead costs a round-trip per queue per
      # column, which on an app with sixty queues is most of a page render.
      @queues = backend.queue_summaries
      @total_size = @queues.sum(&:size)
      @queues = @queues.select { |q| q.name.to_s.downcase.include?(@query.downcase) } if @query.present?
      # Worst first, matching the dashboard and Sidekiq's own convention. Sorted
      # by name the one backed-up queue sits wherever the alphabet puts it,
      # behind however many rows of zeros.
      @queues = @queues.sort_by { |q| [ -q.latency.to_f, -q.size.to_i, q.name.to_s ] }
      @paused = backend.paused_queues
      # Native-pause backends (Solid Queue) enforce pauses without a fetcher, so
      # they never trigger the "not enforced" warning.
      @fetch_installed = backend.supports?(:native_pause) ||
                         (backend.respond_to?(:fetch_installed?) && backend.fetch_installed?)
    end

    # Real, OSS-supported destructive action: empties the queue in Redis.
    def purge
      backend.queue(params[:name]).clear
      redirect_to queues_path, notice: "Purged queue “#{params[:name]}”."
    end

    def pause
      backend.pause(params[:name])
      redirect_to queues_path, notice: "Paused “#{params[:name]}”."
    end

    def resume
      backend.resume(params[:name])
      redirect_to queues_path, notice: "Resumed “#{params[:name]}”."
    end

    # Non-destructive backup — allowed even in read-only mode.
    def snapshot
      snap = RoundhouseUi::Snapshots.take(params[:name])
      redirect_to queues_path, notice: "Snapshot saved — #{snap[:count]} job(s) from “#{params[:name]}”."
    end

    private

    def require_writable!
      return unless RoundhouseUi.read_only
      redirect_to queues_path, alert: "Roundhouse is in read-only mode — queue actions are disabled."
    end
  end
end
