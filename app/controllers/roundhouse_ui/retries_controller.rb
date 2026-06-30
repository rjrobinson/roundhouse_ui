module RoundhouseUi
  class RetriesController < ApplicationController
    include JobSetBrowsing

    before_action :require_writable!, only: %i[requeue destroy bulk_all]

    def index
      @query = params[:q].to_s.strip
      @page  = [ params[:page].to_i, 1 ].max
      @total = Sidekiq::RetrySet.new.size
      @jobs, @has_next = browse(Sidekiq::RetrySet.new, @query, @page)
    end

    # Retry now — moves the job back to its queue immediately.
    def requeue
      entry = Sidekiq::RetrySet.new.find_job(params[:jid])
      entry&.retry
      redirect_to retries_path, notice: entry ? "Re-enqueued #{params[:jid]}." : "Job is no longer in the retry set."
    end

    def destroy
      entry = Sidekiq::RetrySet.new.find_job(params[:jid])
      entry&.delete
      redirect_to retries_path, notice: entry ? "Deleted #{params[:jid]}." : "Job is no longer in the retry set."
    end

    # Smart bulk: retry/delete EVERY job matching the current filter, capped for
    # safety. Offered only when a filter is active.
    def bulk_all
      count, capped = bulk_apply(Sidekiq::RetrySet.new, params[:q].to_s.strip, params[:op])
      verb = params[:op] == "delete" ? "Deleted" : "Re-enqueued"
      note = "#{verb} #{count} matching job(s)."
      note += " Stopped at the #{JobSetBrowsing::BULK_CAP} cap — run again for more." if capped
      redirect_to retries_path, notice: note
    end

    private

    def require_writable!
      return unless RoundhouseUi.read_only
      redirect_to retries_path, alert: "Roundhouse is in read-only mode — retry and delete are disabled."
    end
  end
end
