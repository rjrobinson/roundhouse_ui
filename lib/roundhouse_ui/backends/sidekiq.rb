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
      # all the sets/views. On OSS Sidekiq pause is NOT native (it needs our
      # fetcher), so :native_pause is withheld and the "not enforced" warning
      # applies — but Sidekiq Pro ships its own enforced pause, so there it is
      # advertised and the warning drops away.
      CAPABILITIES = %i[retries dead scheduled busy workers redis capsules].freeze

      def supports?(capability)
        return RoundhouseUi::Pause.native? if capability == :native_pause

        CAPABILITIES.include?(capability)
      end

      def stats        = ::Sidekiq::Stats.new
      def queues       = ::Sidekiq::Queue.all
      def queue(name)  = ::Sidekiq::Queue.new(name)

      # The jobs waiting on one queue. Sidekiq::Queue is Enumerable and pages
      # through Redis in chunks, so callers that stop early (browse fills one
      # page and breaks) never load a large queue into memory.
      def queue_jobs(name) = ::Sidekiq::Queue.new(name)

      # Total worker threads across every reporting process, for the capacity
      # figure (#36). Deliberately not Stats#workers_size, which counts threads
      # *busy this instant* — that goes to zero on an idle fleet, and dividing a
      # required rate by it would claim the fleet has infinite headroom.
      def concurrency
        ::Sidekiq::ProcessSet.new.sum { |p| p["concurrency"].to_i }
      rescue StandardError
        nil
      end

      # Depth and latency for every queue in two Redis round-trips, regardless
      # of how many queues there are.
      #
      # Sidekiq::Queue#size and #latency each issue their own command, so the
      # obvious `queues.map { ... }` costs one SSCAN plus a LLEN and an LRANGE
      # per queue — on an app with sixty queues, a couple of hundred round-trips
      # to render one page. Sidekiq's own Queues#lengths pipelines the LLENs for
      # the same reason; this pipelines the LRANGEs alongside them.
      #
      # Queues with no ready work are kept, at size 0: an operator has to be able
      # to pause or snapshot a queue that happens to be empty right now.
      def queue_summaries
        # Sidekiq 8 ships an equivalent (Stats#queue_summaries) but 6.5 and 7 do
        # not, and its Data objects carry a `paused` field ours cannot. Branching
        # on it would hand callers a different shape depending on which Sidekiq
        # the host runs, so this stays one implementation for every supported
        # version — the reason the gem is portable in the first place.
        names = ::Sidekiq.redis { |c| c.call("SMEMBERS", "queues") }.sort
        return [] if names.empty?

        sizes, oldest = batch_read(names).each_slice(names.size).to_a
        names.each_with_index.map do |name, i|
          RoundhouseUi::QueueSummary.new(name: name, size: sizes[i].to_i,
                                        latency: latency_from(oldest[i]))
        end
      end

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

      private

      # Everything goes through conn.call, whose splat signature is identical on
      # redis-rb (Sidekiq 6.x) and redis-client (7+) — the same reason the rest of
      # this gem avoids the high-level command methods. Pipelining is
      # feature-detected the way DurationCollector does it.
      def batch_read(names)
        commands = names.map { |n| [ "LLEN", "queue:#{n}" ] } +
                   names.map { |n| [ "LRANGE", "queue:#{n}", -1, -1 ] }
        ::Sidekiq.redis do |conn|
          if conn.respond_to?(:pipelined)
            conn.pipelined { |pipe| commands.map { |c| pipe.call(*c) } }
          else
            commands.map { |c| conn.call(*c) }
          end
        end
      end

      # The tail entry of a list is its oldest.
      #
      # Two timestamp formats exist and the difference is three orders of
      # magnitude: Sidekiq 8 writes enqueued_at as integer epoch milliseconds,
      # 6.5 and 7 write float epoch seconds. Treating one as the other does not
      # produce a slightly wrong latency, it produces nonsense. This mirrors the
      # dispatch in Sidekiq 8's own ApiUtils#calculate_latency.
      #
      # A payload that will not parse must not take down the page.
      def latency_from(entry)
        payload = entry.is_a?(Array) ? entry.first : entry
        return 0.0 unless payload

        at = RoundhouseUi.enqueued_at(::Sidekiq.load_json(payload))
        at ? (Time.now - at).to_f : 0.0
      rescue StandardError
        0.0
      end

      public

      # --- pause (via the opt-in Roundhouse fetcher; not native) ---
      def paused_queues     = RoundhouseUi::Pause.paused_set
      def pause(name)       = RoundhouseUi::Pause.pause!(name)
      def resume(name)      = RoundhouseUi::Pause.unpause!(name)
      def fetch_installed?  = RoundhouseUi::Pause.fetch_installed?
    end
  end
end
