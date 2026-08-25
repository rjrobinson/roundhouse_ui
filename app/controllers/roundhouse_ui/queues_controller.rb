module RoundhouseUi
  class QueuesController < ApplicationController
    include JobSetBrowsing

    # Taking a backup writes nothing an operator can lose; restoring one does, and
    # that stays guarded. This was previously expressed by omission from an `only:`
    # list, which is indistinguishable from having forgotten.
    allow_in_read_only :snapshot

    def index
      @query = params[:q].to_s.strip
      # queue_summaries reads depth and latency for every queue in one batch.
      # Mapping over backend.queues instead costs a round-trip per queue per
      # column, which on an app with sixty queues is most of a page render.
      @queues = backend.queue_summaries
      @total_size = @queues.sum(&:size)
      @queues = @queues.select { |q| q.name.to_s.downcase.include?(@query.downcase) } if @query.present?
      # Worst first, matching the dashboard and Sidekiq's own convention. Sorted
      # by name the one backed-up queue sits wherever the alphabet puts it,
      # behind however many rows of zeros.
      @queues = @queues.sort_by { |q| [ -q.latency.to_f, -q.size.to_i, q.name.to_s ] }
      @paused = backend.paused_queues
      # State filter. Counts come from the unfiltered set so the chips still say
      # how many are on the other side of the filter — a chip that reads "0" once
      # you have selected it is useless for getting back.
      @state = params[:state].to_s
      @state_counts = { "paused" => @queues.count { |q| @paused.include?(q.name) } }
      @state_counts["active"] = @queues.size - @state_counts["paused"]
      case @state
      when "paused" then @queues = @queues.select { |q| @paused.include?(q.name) }
      when "active" then @queues = @queues.reject { |q| @paused.include?(q.name) }
      end
      # Native-pause backends (Solid Queue) enforce pauses without a fetcher, so
      # they never trigger the "not enforced" warning.
      @fetch_installed = backend.supports?(:native_pause) ||
                         (backend.respond_to?(:fetch_installed?) && backend.fetch_installed?)
    end

    # The jobs waiting on one queue — what Sidekiq Web shows and we did not.
    # Goes through the shared browse path, so it pages rather than loading a
    # queue that could hold hundreds of thousands of jobs, and inherits search
    # and the tag filter for free.
    def show
      @name = params[:name]
      @query = params[:q].to_s.strip
      @tag = tag_filter
      @page = [ params[:page].to_i, 1 ].max
      summary = backend.queue_summaries.find { |q| q.name == @name }
      @total = summary&.size.to_i
      @latency = summary&.latency
      @paused = backend.paused_queues.include?(@name)
      @jobs, @has_next = browse(backend.queue_jobs(@name), @query, @page, PER_PAGE, tag: @tag)
    end

    # Real, OSS-supported destructive action: empties the queue in Redis.
    def purge
      backend.queue(params[:name]).clear
      redirect_to queues_path, notice: "Purged queue “#{params[:name]}”."
    end

    def pause
      backend.pause(params[:name])
      redirect_to queues_path, notice: "Paused “#{params[:name]}”."
    end

    def resume
      backend.resume(params[:name])
      redirect_to queues_path, notice: "Resumed “#{params[:name]}”."
    end

    # Non-destructive backup — allowed even in read-only mode.
    def snapshot
      snap = RoundhouseUi::Snapshots.take(params[:name])
      redirect_to queues_path, notice: "Snapshot saved — #{snap[:count]} job(s) from “#{params[:name]}”."
    end

    private

    def read_only_redirect_path = queues_path
  end
end
