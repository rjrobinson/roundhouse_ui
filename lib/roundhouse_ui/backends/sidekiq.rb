module RoundhouseUi
  module Backends
    # The Sidekiq implementation of the Roundhouse backend port. It is a thin
    # seam over Sidekiq's own API objects — controllers ask the backend for a
    # "set" or "stats" instead of naming `Sidekiq::*` directly, so a second
    # backend (Solid Queue) can supply duck-typed equivalents without touching
    # controllers or views.
    #
    # Deliberately thin for now: each method returns the same Sidekiq object the
    # controllers used before, so this refactor changes no behavior. The contract
    # (what a "set" / "entry" must respond to) will be firmed up as the Solid
    # Queue backend is built against it.
    class Sidekiq
      def name = "Sidekiq"

      # Capabilities let the UI hide what a backend can't do. Sidekiq supports
      # all the sets/views; pause is NOT native (needs the fetcher), so it does
      # not advertise :native_pause — the "not enforced" warning still applies.
      CAPABILITIES = %i[retries dead scheduled busy workers redis capsules].freeze
      def supports?(capability) = CAPABILITIES.include?(capability)

      def stats        = ::Sidekiq::Stats.new
      def queues       = ::Sidekiq::Queue.all
      def queue(name)  = ::Sidekiq::Queue.new(name)
      def retry_set    = ::Sidekiq::RetrySet.new
      def dead_set     = ::Sidekiq::DeadSet.new
      def scheduled_set = ::Sidekiq::ScheduledSet.new
      def work_set     = ::Sidekiq::WorkSet.new
      def process_set  = ::Sidekiq::ProcessSet.new

      # The job set a given UI section maps to (used by the job-detail page).
      # Lazy — only builds the requested set.
      def set(kind)
        case kind.to_s
        when "dead"      then dead_set
        when "retry"     then retry_set
        when "scheduled" then scheduled_set
        end
      end

      def push(payload) = ::Sidekiq::Client.push(payload)

      # Currently-executing jobs, normalized to the Busy view's shape. (This
      # normalization used to live in BusyController; it belongs to the backend.)
      def busy
        ::Sidekiq::WorkSet.new.map do |process_id, tid, work|
          if work.respond_to?(:queue) # Sidekiq 7+: Sidekiq::Work struct
            { process: process_id, tid: tid, queue: work.queue, run_at: work.run_at, job: work.job }
          else                         # Sidekiq 6.x: a plain Hash
            { process: process_id, tid: tid, queue: work["queue"],
              run_at: Time.at(work["run_at"]), job: ::Sidekiq::JobRecord.new(work["payload"]) }
          end
        end
      end

      # --- pause (via the opt-in Roundhouse fetcher; not native) ---
      def paused_queues     = RoundhouseUi::Pause.paused_set
      def pause(name)       = RoundhouseUi::Pause.pause!(name)
      def resume(name)      = RoundhouseUi::Pause.unpause!(name)
      def fetch_installed?  = RoundhouseUi::Pause.fetch_installed?
    end
  end
end
