module RoundhouseUi
  class QueuesController < ApplicationController
    before_action :require_writable!, only: %i[purge pause resume]

    def index
      @queues = Sidekiq::Queue.all
      @paused = RoundhouseUi::Pause.paused_set
      @fetch_installed = RoundhouseUi::Pause.fetch_installed?
    end

    # Real, OSS-supported destructive action: empties the queue in Redis.
    def purge
      Sidekiq::Queue.new(params[:name]).clear
      redirect_to queues_path, notice: "Purged queue “#{params[:name]}”."
    end

    def pause
      RoundhouseUi::Pause.pause!(params[:name])
      redirect_to queues_path, notice: "Paused “#{params[:name]}”."
    end

    def resume
      RoundhouseUi::Pause.unpause!(params[:name])
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
