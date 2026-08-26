module RoundhouseUi
  class RetriesController < ApplicationController
    include JobSetBrowsing

    guard_in_read_only :preview

    def index
      @query = params[:q].to_s.strip
      @page  = [ params[:page].to_i, 1 ].max
      @total = backend.retry_set.size
      @tag = tag_filter
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
      found = bulk_apply(backend.retry_set, params[:q].to_s.strip, params[:op], BULK_CAP, tag: tag_filter)

      # An unfiltered bulk_all selected every entry and reported it as a match.
      # The comment above claimed this was "only offered when a filter is active" —
      # and it was only OFFERED that way; the route had no gate. bulk_matches now
      # refuses at the chokepoint, and this says so out loud rather than reporting
      # "Deleted 0 matching job(s)", which would read like an empty set.
      if found.unfiltered
        return redirect_to retries_path,
          alert: "Refused: a bulk action needs a filter. Without one it would act on " \
                 "every job in the set, which is not what this control is for."
      end

      verb = params[:op] == "delete" ? "Deleted" : "Re-enqueued"
      note = "#{verb} #{found.entries.size} matching job(s)."
      note += " Stopped at the #{JobSetBrowsing::BULK_CAP} cap — run again for more." if found.capped
      redirect_to retries_path, notice: note
    end

    # A dry run: the count tells you how many match, this tells you which (#37).
    def preview
      @op = params[:op] == "delete" ? "delete" : "retry"
      @query = params[:q].to_s.strip
      @tag = tag_filter
      @matched = bulk_matches(backend.retry_set, @query, JobSetBrowsing::BULK_CAP, tag: @tag)
      @confirm_path = bulk_all_retries_path
      @back_path = retries_path
      @set = "retries"
      @noun = "retry"
      render "roundhouse_ui/shared/bulk_preview"
    end

    private

    def read_only_redirect_path = retries_path
  end
end
