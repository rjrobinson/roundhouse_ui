module RoundhouseUi
  class DeadController < ApplicationController
    include JobSetBrowsing

    before_action :require_writable!, only: %i[requeue destroy bulk]

    def index
      @query = params[:q].to_s.strip
      @page  = [ params[:page].to_i, 1 ].max
      @total = Sidekiq::DeadSet.new.size
      @jobs, @has_next = browse(Sidekiq::DeadSet.new, @query, @page)
    end

    def requeue
      entry = Sidekiq::DeadSet.new.find_job(params[:jid])
      entry&.retry
      redirect_to dead_set_path, notice: entry ? "Re-enqueued #{params[:jid]}." : "Job is no longer in the dead set."
    end

    def destroy
      entry = Sidekiq::DeadSet.new.find_job(params[:jid])
      entry&.delete
      redirect_to dead_set_path, notice: entry ? "Deleted #{params[:jid]}." : "Job is no longer in the dead set."
    end

    # Act on many at once: retry or delete every selected job in one request.
    def bulk
      set = Sidekiq::DeadSet.new
      count = 0
      Array(params[:jids]).each do |jid|
        entry = set.find_job(jid) or next
        params[:op] == "delete" ? entry.delete : entry.retry
        count += 1
      end
      verb = params[:op] == "delete" ? "Deleted" : "Re-enqueued"
      redirect_to dead_set_path, notice: "#{verb} #{count} job(s)."
    end

    private

    def require_writable!
      return unless RoundhouseUi.read_only
      redirect_to dead_set_path, alert: "Roundhouse is in read-only mode — retry and delete are disabled."
    end
  end
end
