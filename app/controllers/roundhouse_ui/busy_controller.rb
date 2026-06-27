module RoundhouseUi
  # What's executing right now, from Sidekiq::WorkSet — the live in-flight jobs
  # Sidekiq Web calls "Busy". Surfaces long-running (possibly hung) jobs, which
  # the stock UI makes you eyeball.
  class BusyController < ApplicationController
    LONG_RUNNING = 60 # seconds

    before_action :require_writable!, only: :cancel

    def index
      @threshold = LONG_RUNNING
      @work = Sidekiq::WorkSet.new.map do |process_id, tid, work|
        { process: process_id, tid: tid, queue: work.queue, run_at: work.run_at, job: work.job }
      end
    end

    def cancel
      RoundhouseUi::Cancellation.cancel!(params[:jid])
      redirect_to busy_path, notice: "Cancellation requested for #{params[:jid]}."
    end

    private

    def require_writable!
      return unless RoundhouseUi.read_only
      redirect_to busy_path, alert: "Roundhouse is in read-only mode — cancellation is disabled."
    end
  end
end
