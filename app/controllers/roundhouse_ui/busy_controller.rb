module RoundhouseUi
  # What's executing right now, from Sidekiq::WorkSet — the live in-flight jobs
  # Sidekiq Web calls "Busy". Surfaces long-running (possibly hung) jobs, which
  # the stock UI makes you eyeball.
  class BusyController < ApplicationController
    LONG_RUNNING = 60 # seconds

    before_action :require_cancellable!, only: :cancel
    before_action :require_writable!, only: :cancel

    def index
      @threshold = LONG_RUNNING
      @work = backend.busy
      # "4m 12s" means nothing on its own — fine for a nightly rollup, a hang for
      # a webhook. DurationCollector already records the average per class, so
      # where it is enabled the page can say "×8 typical" instead. Empty
      # otherwise, and the view degrades to elapsed with no ceiling.
      @typical = typical_durations
    end

    def cancel
      RoundhouseUi::Cancellation.cancel!(params[:jid])
      redirect_to busy_path, notice: "Cancellation requested for #{params[:jid]}."
    end

    private

    # Average seconds per class, keyed by the real job class so an ActiveJob
    # wrapper does not collapse every mailer into one baseline.
    def typical_durations
      return {} unless RoundhouseUi.collect_durations

      DurationCollector.summary.to_h { |d| [ d[:klass].to_s, d[:avg_ms].to_f / 1000.0 ] }
    rescue StandardError
      {}
    end

    def require_writable!
      return unless RoundhouseUi.read_only
      redirect_to busy_path, alert: "Roundhouse is in read-only mode — cancellation is disabled."
    end

    # Hiding the button is presentation; this is the control. Without a backend
    # that can cancel and a host-side check that reads the flag, cancel! only
    # writes a JID nobody consumes.
    def require_cancellable!
      return if RoundhouseUi.cancel_enabled && backend.supports?(:cancel)
      redirect_to busy_path, alert: "Cancellation is not enabled — see RoundhouseUi.cancel_enabled."
    end
  end
end
