module RoundhouseUi
  class RetriesController < ApplicationController
    include JobSetBrowsing

    before_action :require_writable!, only: %i[requeue destroy bulk_all]

    def index
      @query = params[:q].to_s.strip
      @page  = [ params[:page].to_i, 1 ].max
      @total = backend.retry_set.size
      @tag = tag_filter
      @queue_filter = queue_filter
      @jobs, @has_next = browse(backend.retry_set, @query, @page, PER_PAGE, tag: @tag)
    end

    # Retry now — moves the job back to its queue immediately.
    def requeue
      entry = backend.retry_set.find_job(params[:jid])
      entry&.retry
      redirect_to retries_path, notice: entry ? "Re-enqueued #{params[:jid]}." : "Job is no longer in the retry set."
    end

    def destroy
      entry = backend.retry_set.find_job(params[:jid])
      entry&.delete
      redirect_to retries_path, notice: entry ? "Deleted #{params[:jid]}." : "Job is no longer in the retry set."
    end

    # Smart bulk: retry/delete EVERY job matching the current filter, capped for
    # safety. Offered only when a filter is active.
    def bulk_all
      @queue_filter = queue_filter
      count, capped = bulk_apply(backend.retry_set, params[:q].to_s.strip, params[:op], BULK_CAP, tag: tag_filter)
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
