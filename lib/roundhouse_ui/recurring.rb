module RoundhouseUi
  # Periodic work, normalised across the four things that schedule it.
  #
  # There is no shared API: sidekiq-cron, sidekiq-scheduler, Sidekiq Enterprise's
  # periodic loops and Solid Queue's recurring tasks each expose something
  # different. So this detects what is loaded and adapts, the same way the
  # backend port does — nothing to configure, and the nav item hides when nothing
  # is present. See #62.
  #
  # Reading only. A UI that lets someone silently change a production schedule is
  # a different risk conversation, and the schedule belongs in the code that
  # defines it.
  module Recurring
    Task = Struct.new(:name, :schedule, :klass, :queue, :last_run, :enabled, :source,
                      keyword_init: true) do
      def enabled? = enabled != false

      # The interesting question is not "what is the crontab" — it is "this says
      # hourly and has not run in three days". That needs the schedule's expected
      # interval, which needs a cron parser.
      #
      # Fugit ships with both sidekiq-cron and sidekiq-scheduler, so it is present
      # wherever this feature is. Where it is not, staleness is simply unknown
      # rather than guessed.
      def expected_interval
        return nil unless defined?(::Fugit)

        parsed = ::Fugit.parse(schedule.to_s)
        return nil unless parsed.respond_to?(:next_time)

        a = parsed.next_time(Time.now)
        b = parsed.next_time(a.to_t + 1)
        (b.to_t - a.to_t).to_f
      rescue StandardError
        nil
      end

      # Overdue by more than one whole interval. One interval of slack on purpose:
      # a job due at :00 and running at :00:07 is not late, and a view that says it
      # is gets ignored.
      def overdue?
        interval = expected_interval
        return false if interval.nil? || last_run.nil? || !enabled?

        Time.now - last_run > interval * 2
      end

      def status
        return :paused unless enabled?
        return :unknown if last_run.nil?

        overdue? ? :overdue : :ok
      end
    end
    module_function

    # Every source that is loaded, merged. An app can genuinely run two — a
    # sidekiq-cron schedule inherited from an old migration alongside Solid
    # Queue's own — and hiding one of them would be worse than showing both.
    # Overdue first, then by name — the order is information, same rule as
    # everywhere else, and a stable tiebreak so it does not shuffle.
    def tasks
      SOURCES.flat_map { |name, reader| detected?(name) ? safely(name, &reader) : [] }
             .sort_by { |t| [ t.overdue? ? 0 : 1, t.name.to_s ] }
    end

    def any? = SOURCES.keys.any? { |n| detected?(n) }

    def detected?(name)
      case name
      when :sidekiq_cron      then defined?(::Sidekiq::Cron::Job)
      when :sidekiq_scheduler then defined?(::SidekiqScheduler::Schedule) || defined?(::Sidekiq::Scheduler)
      when :sidekiq_ent       then defined?(::Sidekiq::Periodic::LoopSet)
      when :solid_queue       then defined?(::SolidQueue::RecurringTask)
      end
    end

    # A broken or half-configured scheduler must not take the page down, and it
    # must not hide the schedulers that ARE working.
    def safely(name)
      result = yield
      # NOT Array(): a Struct responds to to_a, so Array(task) splats a single
      # task into its seven field values instead of wrapping it.
      result.is_a?(Array) ? result : [ result ].compact
    rescue StandardError => e
      Rails.logger&.warn("[roundhouse] recurring source #{name} failed: #{e.message}") if defined?(Rails)
      []
    end

    SOURCES = {
      sidekiq_cron: lambda do
        ::Sidekiq::Cron::Job.all.map do |j|
          Task.new(name: j.name, schedule: j.cron, klass: j.klass, queue: j.queue,
                   last_run: j.last_enqueue_time, enabled: j.status != "disabled",
                   source: "sidekiq-cron")
        end
      end,

      sidekiq_scheduler: lambda do
        (::Sidekiq.schedule || {}).map do |name, cfg|
          Task.new(name: name,
                   schedule: cfg["cron"] || cfg["every"] || cfg["interval"] || cfg[:cron],
                   klass: cfg["class"] || cfg[:class], queue: cfg["queue"] || cfg[:queue],
                   last_run: scheduler_last_run(name),
                   enabled: cfg["enabled"] != false,
                   source: "sidekiq-scheduler")
        end
      end,

      sidekiq_ent: lambda do
        ::Sidekiq::Periodic::LoopSet.new.map do |loop_|
          Task.new(name: loop_.klass, schedule: loop_.schedule, klass: loop_.klass,
                   queue: loop_.options&.dig("queue"),
                   last_run: (Time.at(loop_.last_enqueue_time.to_i) if loop_.last_enqueue_time),
                   enabled: true, source: "sidekiq-ent")
        end
      end,

      solid_queue: lambda do
        ::SolidQueue::RecurringTask.all.map do |t|
          Task.new(name: t.key, schedule: t.schedule, klass: t.class_name, queue: t.queue_name,
                   last_run: t.recurring_executions.maximum(:run_at),
                   enabled: true, source: "solid-queue")
        end
      end
    }.freeze

    def scheduler_last_run(name)
      return nil unless defined?(::SidekiqScheduler::RedisManager)

      raw = ::SidekiqScheduler::RedisManager.get_job_last_time(name)
      raw && Time.parse(raw.to_s)
    rescue StandardError
      nil
    end
  end
end
