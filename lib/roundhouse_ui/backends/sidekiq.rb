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
    end
  end
end
