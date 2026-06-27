module RoundhouseUi
  class ScheduledController < ApplicationController
    include JobSetBrowsing

    before_action :require_writable!, only: %i[enqueue destroy]

    def index
      @query = params[:q].to_s.strip
      @page  = [ params[:page].to_i, 1 ].max
      @total = Sidekiq::ScheduledSet.new.size
      @jobs, @has_next = browse(Sidekiq::ScheduledSet.new, @query, @page)
    end

    # Enqueue now — pulls the job out of the schedule and onto its queue.
    def enqueue
      entry = Sidekiq::ScheduledSet.new.find_job(params[:jid])
      entry&.add_to_queue
      redirect_to scheduled_path, notice: entry ? "Enqueued #{params[:jid]} now." : "Job is no longer scheduled."
    end

    def destroy
      entry = Sidekiq::ScheduledSet.new.find_job(params[:jid])
      entry&.delete
      redirect_to scheduled_path, notice: entry ? "Deleted #{params[:jid]}." : "Job is no longer scheduled."
    end

    private

    def require_writable!
      return unless RoundhouseUi.read_only
      redirect_to scheduled_path, alert: "Roundhouse is in read-only mode — enqueue and delete are disabled."
    end
  end
end
