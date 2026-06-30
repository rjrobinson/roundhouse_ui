module RoundhouseUi
  # What's executing right now, from Sidekiq::WorkSet — the live in-flight jobs
  # Sidekiq Web calls "Busy". Surfaces long-running (possibly hung) jobs, which
  # the stock UI makes you eyeball.
  class BusyController < ApplicationController
    LONG_RUNNING = 60 # seconds

    before_action :require_writable!, only: :cancel

    def index
      @threshold = LONG_RUNNING
      @work = Sidekiq::WorkSet.new.map { |process_id, tid, work| normalize(process_id, tid, work) }
    end

    def cancel
      RoundhouseUi::Cancellation.cancel!(params[:jid])
      redirect_to busy_path, notice: "Cancellation requested for #{params[:jid]}."
    end

    private

    # Sidekiq 7+ yields a Sidekiq::Work (queue/run_at/job methods); Sidekiq 6.x
    # yields a plain Hash (string keys, an epoch run_at, a JSON payload). Normalize
    # both to the same shape the view expects (run_at as a Time, job as a JobRecord).
    def normalize(process_id, tid, work)
      if work.respond_to?(:queue)
        { process: process_id, tid: tid, queue: work.queue, run_at: work.run_at, job: work.job }
      else
        { process: process_id, tid: tid, queue: work["queue"],
          run_at: Time.at(work["run_at"]), job: Sidekiq::JobRecord.new(work["payload"]) }
      end
    end

    def require_writable!
      return unless RoundhouseUi.read_only
      redirect_to busy_path, alert: "Roundhouse is in read-only mode — cancellation is disabled."
    end
  end
end
