module RoundhouseUi
  class QueuesController < ApplicationController
    before_action :require_writable!, only: %i[purge pause resume]

    def index
      @queues = backend.queues
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
