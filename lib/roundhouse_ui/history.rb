module RoundhouseUi
  # Daily processed and failed counts, for the one question every other number on
  # the dashboard cannot answer: is this normal?
  #
  # 30,655 failures is alarming or unremarkable depending on the day, and a live
  # throughput chart that starts empty on every page load cannot tell you which.
  #
  # Sidekiq already records this — `Sidekiq::Stats::History` keeps a counter per
  # day and Roundhouse ignored it entirely. So this needs no storage of its own,
  # no migration, and it works on every Sidekiq install. See #61.
  Day = Struct.new(:date, :processed, :failed, keyword_init: true) do
    # Share of the day's work that failed. The line worth drawing: counts move
    # with traffic, so a busy Monday looks worse than a quiet Sunday even when
    # nothing changed. A rate does not.
    def failure_rate
      total = processed.to_i + failed.to_i
      return 0.0 if total.zero?

      failed.to_i / total.to_f
    end

    def quiet? = processed.to_i.zero? && failed.to_i.zero?
  end

  module History
    RANGES = { "7" => "1 week", "30" => "1 month", "90" => "3 months", "180" => "6 months" }.freeze
    DEFAULT_DAYS = 30
    MAX_DAYS = 180

    module_function

    # Oldest first, so a chart can plot it without reversing.
    def days(count = DEFAULT_DAYS, backend: RoundhouseUi.backend)
      return [] unless backend.respond_to?(:history) && backend.supports?(:history)

      backend.history(clamp(count))
    rescue StandardError => e
      Rails.logger&.warn("[roundhouse] history unavailable: #{e.message}") if defined?(Rails)
      []
    end

    def clamp(count) = count.to_i.clamp(1, MAX_DAYS)

    # A baseline to compare today against. The median rather than the mean: one
    # incident day would drag a mean up and make the following week look calm.
    def typical_failure_rate(days)
      rates = days.reject(&:quiet?).map(&:failure_rate).sort
      return nil if rates.empty?

      mid = rates.size / 2
      rates.size.odd? ? rates[mid] : (rates[mid - 1] + rates[mid]) / 2.0
    end
  end
end
