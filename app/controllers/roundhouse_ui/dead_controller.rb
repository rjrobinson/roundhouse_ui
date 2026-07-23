module RoundhouseUi
  class DeadController < ApplicationController
    include JobSetBrowsing

    before_action :require_writable!, only: %i[requeue destroy bulk bulk_all]

    def index
      @query = params[:q].to_s.strip
      @page  = [ params[:page].to_i, 1 ].max
      @total = backend.dead_set.size
      @jobs, @has_next = browse(backend.dead_set, @query, @page)
    end

    def requeue
      entry = backend.dead_set.find_job(params[:jid])
      entry&.retry
      redirect_to dead_set_path, notice: entry ? "Re-enqueued #{params[:jid]}." : "Job is no longer in the dead set."
    end

    def destroy
      entry = backend.dead_set.find_job(params[:jid])
      entry&.delete
      redirect_to dead_set_path, notice: entry ? "Deleted #{params[:jid]}." : "Job is no longer in the dead set."
    end

    # Act on many at once: retry or delete every selected job in one request.
    def bulk
      set = backend.dead_set
      count = 0
      Array(params[:jids]).each do |jid|
        entry = set.find_job(jid) or next
        params[:op] == "delete" ? entry.delete : entry.retry
        count += 1
      end
      verb = params[:op] == "delete" ? "Deleted" : "Re-enqueued"
      redirect_to dead_set_path, notice: "#{verb} #{count} job(s)."
    end

    # Smart bulk: act on EVERY job matching the current filter (not just the
    # selected/visible ones), capped for safety. Only offered when a filter is
    # active, so it can't become "retry the entire dead set" by accident.
    def bulk_all
      count, capped = bulk_apply(backend.dead_set, params[:q].to_s.strip, params[:op])
      verb = params[:op] == "delete" ? "Deleted" : "Re-enqueued"
      note = "#{verb} #{count} matching job(s)."
      note += " Stopped at the #{JobSetBrowsing::BULK_CAP} cap — run again for more." if capped
      redirect_to dead_set_path, notice: note
    end

    private

    def require_writable!
      return unless RoundhouseUi.read_only
      redirect_to dead_set_path, alert: "Roundhouse is in read-only mode — retry and delete are disabled."
    end
  end
end
