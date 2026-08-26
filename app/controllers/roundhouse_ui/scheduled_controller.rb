module RoundhouseUi
  class ScheduledController < ApplicationController
    include JobSetBrowsing

    def index
      @query = params[:q].to_s.strip
      @page  = [ params[:page].to_i, 1 ].max
      @total = backend.scheduled_set.size
      @tag = tag_filter
      @jobs, @has_next = browse(backend.scheduled_set, @query, @page, PER_PAGE, tag: @tag)
    end

    # Enqueue now — pulls the job out of the schedule and onto its queue.
    def enqueue
      entry = backend.scheduled_set.find_job(params[:jid])
      entry&.add_to_queue
      redirect_to scheduled_path, notice: entry ? "Enqueued #{params[:jid]} now." : "Job is no longer scheduled."
    end

    def destroy
      entry = backend.scheduled_set.find_job(params[:jid])
      entry&.delete
      redirect_to scheduled_path, notice: entry ? "Deleted #{params[:jid]}." : "Job is no longer scheduled."
    end

    private

    def read_only_redirect_path = scheduled_path
  end
end
