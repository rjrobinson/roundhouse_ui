require "json"

module RoundhouseUi
  module Backends
    # Solid Queue implementation of the backend port. Reads Solid Queue's
    # ActiveRecord tables and normalizes them to the same shape the Sidekiq
    # backend exposes, so controllers/views don't change.
    #
    # Solid Queue has no "retry set" (retries are just re-scheduled executions),
    # no Redis, and no capsules — the UI hides those via #supports?. Queue pause
    # is native, so there's no fetcher to warn about.
    class SolidQueue
      def name = "Solid Queue"

      # No retries/redis/capsules/workers (deferred); pause is native (no fetcher
      # warning). dead/scheduled/busy are supported.
      CAPABILITIES = %i[dead scheduled busy native_pause].freeze
      def supports?(capability) = CAPABILITIES.include?(capability)

      def stats
        Stats.new(
          processed: sq(:Job).where.not(finished_at: nil).count,
          failed:    sq(:FailedExecution).count,
          enqueued:  sq(:ReadyExecution).count,
          scheduled: sq(:ScheduledExecution).count,
          busy:      sq(:ClaimedExecution).count,
          dead:      sq(:FailedExecution).count,
          retries:   0
        )
      end

      def queues = ::SolidQueue::Queue.all
      def queue(name) = ::SolidQueue::Queue.new(name)

      # Depth and latency for every queue in two queries, not two per queue.
      #
      # SolidQueue::Queue#size and #latency each run their own COUNT and MIN, so
      # rendering the Queues page over sixty queues meant well over a hundred
      # round-trips to the queue database. One GROUP BY answers both for every
      # queue at once.
      #
      # Queue.all is still consulted, because it lists queues by distinct job
      # name — including ones with nothing ready right now — and an operator has
      # to be able to pause or clear a queue that happens to be empty.
      def queue_summaries
        counts = sq(:ReadyExecution).group(:queue_name)
                                    .pluck(Arel.sql("queue_name, COUNT(*), MIN(created_at)"))
                                    .to_h { |name, size, oldest| [ name, [ size, oldest ] ] }

        names = (::SolidQueue::Queue.all.map(&:name) | counts.keys).sort
        now = Time.current
        names.map do |name|
          size, oldest = counts[name]
          RoundhouseUi::QueueSummary.new(
            name: name, size: size.to_i,
            latency: oldest ? (now - oldest).to_i : 0
          )
        end
      end

      # No retry set in Solid Queue — surfaced via supports?(:retries) => false.
      def retry_set = EMPTY_SET

      # Workers view is deferred (supports?(:workers) == false), and Solid Queue
      # processes don't report thread concurrency the way Metrics expects, so the
      # utilization signal reads as "no workers reporting" rather than crashing.
      def process_set = []

      def dead_set      = JobSet.new(sq(:FailedExecution).includes(:job).order(created_at: :desc))
      def scheduled_set = JobSet.new(sq(:ScheduledExecution).includes(:job).order(:scheduled_at))

      # Currently-executing jobs, normalized to the Busy view's shape.
      def busy
        sq(:ClaimedExecution).includes(:job, :process).map do |claim|
          e = Entry.new(claim)
          { process: claim.process&.name, tid: claim.id, queue: e.queue, run_at: claim.created_at, job: e }
        end
      end

      def set(kind)
        case kind.to_s
        when "dead"      then dead_set
        when "scheduled" then scheduled_set
        end
      end

      # --- pause (native) ---
      def paused_queues = ::SolidQueue::Pause.pluck(:queue_name)
      def pause(name)   = ::SolidQueue::Queue.new(name).pause
      def resume(name)  = ::SolidQueue::Queue.new(name).resume

      # ActiveJob enqueues via perform_later; a raw push has no direct analogue.
      def push(_payload) = raise NotImplementedError, "enqueue is Sidekiq-only for now"

      private

      def sq(model) = ::SolidQueue.const_get(model)

      # A collection matching the JobSet contract (each / find_job / size).
      class JobSet
        include Enumerable
        def initialize(relation) = @relation = relation
        def each(&blk) = @relation.each { |exec| blk.call(Entry.new(exec)) }
        def size = @relation.count
        def find_job(jid) = (exec = @relation.find_by(job_id: jid)) && Entry.new(exec)
      end

      EMPTY_SET = JobSet.new([]).freeze

      # Wraps a Solid Queue execution + its job in the SortedEntry-like interface
      # the views expect (klass / jid / args / item / at / queue / retry / delete).
      class Entry
        def initialize(execution)
          @execution = execution
          @job = execution.job
        end

        def jid   = @execution.job_id.to_s
        def klass = @job&.class_name
        def queue = @job&.queue_name
        def args  = active_job_args
        def at    = @execution.try(:scheduled_at) || @execution.try(:created_at)

        def item
          err = (@execution.respond_to?(:error) && @execution.error) || {}
          {
            "class" => klass, "args" => args, "queue" => queue,
            "error_class"     => err["exception_class"],
            "error_message"   => err["message"],
            "error_backtrace" => err["backtrace"]
          }
        end

        def retry = @execution.retry if @execution.respond_to?(:retry)
        def delete = @execution.destroy

        private

        # Solid Queue stores the full ActiveJob payload; the caller-facing args
        # live under "arguments".
        def active_job_args
          raw = @job&.arguments
          data = raw.is_a?(String) ? JSON.parse(raw) : raw
          data.is_a?(Hash) ? (data["arguments"] || []) : Array(data)
        rescue JSON::ParserError
          []
        end
      end

      # Value object matching Sidekiq::Stats' reader surface.
      Stats = Struct.new(:processed, :failed, :enqueued, :scheduled, :busy, :dead, :retries, keyword_init: true) do
        def scheduled_size = scheduled
        def retry_size     = retries
        def dead_size      = dead
        def workers_size   = busy
      end
    end
  end
end
