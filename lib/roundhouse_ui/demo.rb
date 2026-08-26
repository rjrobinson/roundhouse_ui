# frozen_string_literal: true

require "digest"
require "securerandom"

module RoundhouseUi
  # Workers that do real work and really fail, so a console has something to show.
  #
  # NOT loaded by `require "roundhouse_ui"`. Ask for it explicitly, in an
  # initializer you would not ship:
  #
  #   require "roundhouse_ui/demo" if Rails.env.development?
  #
  # Then drive it with `rake roundhouse_ui:demo:load[10]`.
  #
  # Each class refuses to run outside development or test. A worker that sleeps
  # for twelve seconds and then raises is a fine thing to have in a demo and a
  # bad thing to have reachable in production, and "nobody will enqueue it" is
  # not a control.
  module Demo
    class Base
      include Sidekiq::Job

      # Three attempts, so a failing job reaches the dead set inside a short
      # demo instead of backing off for hours.
      sidekiq_options retry: 3

      # Subclasses override. Milliseconds of work, and the chance of failing.
      DURATION = (100..400)
      FAILURE_RATE = 0.0
      ERRORS = [ [ RuntimeError, "something went wrong" ] ].freeze

      def perform(payload = {})
        unless %w[development test].include?(ENV["RAILS_ENV"] || Rails.env.to_s)
          raise "RoundhouseUi::Demo workers do not run outside development"
        end

        work_for(self.class::DURATION)
        maybe_fail(payload)
      end

      private

      # Real elapsed time, and real CPU — a job that only sleeps shows up on the
      # Busy page but never in a flame graph, and the point is to look like work.
      def work_for(range)
        budget = rand(range) / 1000.0
        deadline = now + budget
        digest = SecureRandom.hex(8)
        while now < deadline
          200.times { digest = Digest::SHA256.hexdigest(digest) }
          sleep 0.01
        end
        digest
      end

      def maybe_fail(payload)
        return if rand >= self.class::FAILURE_RATE

        klass, message = self.class::ERRORS.sample
        raise klass, "#{message} (account #{payload['account_id'] || '—'})"
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # A payment path: quick, and fails often enough to group.
    class CheckoutWorker < Base
      OWNER = :core
      QUEUE = "stripe"
      DURATION = (200..1_200)
      FAILURE_RATE = 0.18
      ERRORS = [
        [ Timeout::Error, "Stripe API timed out after 8s" ],
        [ ArgumentError, "no such price" ]
      ].freeze
    end

    # Mail: fast and mostly reliable, so the throughput line has volume.
    class DigestMailerWorker < Base
      OWNER = :growth
      QUEUE = "invite_mailer"
      DURATION = (60..300)
      FAILURE_RATE = 0.04
      ERRORS = [ [ IOError, "421 4.7.0 Try again later" ] ].freeze
    end

    # Search reindex: slow enough to sit on the Busy page while you look at it.
    class ReindexWorker < Base
      OWNER = :platform
      QUEUE = "default"
      DURATION = (1_500..5_000)
      FAILURE_RATE = 0.09
      ERRORS = [ [ IOError, "connection reset by peer" ] ].freeze
    end

    # The long one: guaranteed to be mid-flight whenever you open Busy.
    class TranscodeWorker < Base
      OWNER = :platform
      QUEUE = "uploaded_files"
      DURATION = (6_000..20_000)
      FAILURE_RATE = 0.07
      ERRORS = [ [ RuntimeError, "ffmpeg exited with status 1" ] ].freeze
    end

    # The flaky one: the group that dominates the Errors page.
    class EmbeddingWorker < Base
      OWNER = :ai
      QUEUE = "ai"
      DURATION = (400..2_500)
      FAILURE_RATE = 0.24
      ERRORS = [
        [ Timeout::Error, "embedding endpoint timed out" ],
        [ RuntimeError, "429 rate limited" ],
        [ KeyError, "key not found: :embedding" ]
      ].freeze
    end

    class GamificationWorker < Base
      OWNER = :training
      QUEUE = "gamification"
      DURATION = (100..600)
      FAILURE_RATE = 0.06
      ERRORS = [ [ RuntimeError, "badge already awarded" ] ].freeze
    end

    ALL = [ CheckoutWorker, DigestMailerWorker, ReindexWorker,
            TranscodeWorker, EmbeddingWorker, GamificationWorker ].freeze
  end
end
