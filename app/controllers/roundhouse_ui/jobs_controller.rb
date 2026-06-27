module RoundhouseUi
  # Enqueue new jobs and edit/re-enqueue existing ones. Opt-in via
  # RoundhouseUi.allow_job_editing (off by default — a sharp tool).
  #
  # Sidekiq has no in-place edit: a job in a set is keyed by its payload, so an
  # "edit" is delete-the-old + push-the-modified.
  class JobsController < ApplicationController
    SET_BUILDERS = {
      "dead"      => -> { Sidekiq::DeadSet.new },
      "retry"     => -> { Sidekiq::RetrySet.new },
      "scheduled" => -> { Sidekiq::ScheduledSet.new }
    }.freeze
    REDIRECTS = { "dead" => :dead_set_path, "retry" => :retries_path, "scheduled" => :scheduled_path }.freeze

    before_action :require_editing_enabled!, except: :show

    # Read-only inspection — available without allow_job_editing.
    def show
      @set = params[:set]
      @entry = find_entry or return redirect_to(root_path, alert: "Job not found.")
    end

    def new
      @mode = :new
      @job  = { "class" => "", "queue" => "default", "args" => "[]" }
      @action_path = jobs_path
    end

    def create
      args  = parse_args!(params[:args])
      klass = params[:job_class].to_s.strip
      raise ArgumentError, "Job class is required" if klass.empty?

      queue = params[:queue].presence || "default"
      Sidekiq::Client.push("class" => klass, "queue" => queue, "args" => args)
      redirect_to queues_path, notice: "Enqueued #{klass} → #{queue}."
    rescue ArgumentError => e
      render_form_error(:new, jobs_path, e)
    end

    def edit
      @entry = find_entry or return redirect_to(root_path, alert: "Job not found.")
      @mode = :edit
      @job = {
        "class" => @entry.item["class"],
        "queue" => @entry.queue,
        "args"  => JSON.pretty_generate(@entry.item["args"] || [])
      }
      @action_path = job_path(set: params[:set], jid: params[:jid])
    end

    def update
      entry = find_entry or return redirect_to(root_path, alert: "Job not found.")
      args  = parse_args!(params[:args])
      klass = params[:job_class].presence || entry.item["class"]
      queue = params[:queue].presence || entry.queue

      entry.delete
      Sidekiq::Client.push("class" => klass, "queue" => queue, "args" => args)
      redirect_to send(REDIRECTS[params[:set]]), notice: "Edited & re-enqueued #{klass} → #{queue}."
    rescue ArgumentError => e
      @action_path = job_path(set: params[:set], jid: params[:jid])
      render_form_error(:edit, @action_path, e)
    end

    private

    def find_entry
      builder = SET_BUILDERS[params[:set]] or return nil
      builder.call.find_job(params[:jid])
    end

    def parse_args!(raw)
      parsed = JSON.parse(raw.to_s)
      raise ArgumentError, 'Arguments must be a JSON array, e.g. [123, "abc"]' unless parsed.is_a?(Array)
      parsed
    rescue JSON::ParserError
      raise ArgumentError, "Arguments must be valid JSON"
    end

    def render_form_error(mode, action_path, error)
      flash.now[:alert] = error.message
      @mode = mode
      @action_path = action_path
      @job = { "class" => params[:job_class], "queue" => params[:queue], "args" => params[:args] }
      render mode, status: :unprocessable_entity
    end

    def require_editing_enabled!
      return if RoundhouseUi.allow_job_editing && !RoundhouseUi.read_only
      redirect_to root_path, alert: "Job editing is off — set RoundhouseUi.allow_job_editing = true (and disable read-only)."
    end
  end
end
