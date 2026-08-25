module RoundhouseUi
  # A composite health verdict for the dashboard. Instead of a static green dot,
  # it rolls up the signals an on-call engineer actually checks — error rate,
  # queue latency, worker utilization — into one status + a human reason, and
  # exposes the sub-signals so the banner can explain *why*.
  class Health
    Signal = Struct.new(:key, :label, :status, :detail, keyword_init: true)

    RANK = { ok: 0, warn: 1, crit: 2 }.freeze

    def initialize(stats:, queues:, metrics:)
      @stats = stats
      @queues = queues
      @metrics = metrics
    end

    # Signals worst-first, the same rule the Queues page sorts by: the order is
    # information, so a failing check should never sit below a healthy one.
    # Ties break on label, so the order is stable between polls.
    def ranked_signals
      signals.sort_by { |s| [ -RANK.fetch(s.status, 0), s.label.to_s ] }
    end

    def failing_count
      signals.count { |s| s.status != :ok }
    end

    def signals
      @signals ||= [ error_rate_signal, latency_signal, utilization_signal ].compact
    end

    # Worst sub-signal wins.
    def status
      signals.map(&:status).max_by { |s| RANK[s] } || :ok
    end

    def reason
      worst = signals.max_by { |s| RANK[s.status] }
      return "all signals nominal" if worst.nil? || worst.status == :ok

      worst.detail
    end

    def healthy?
      status == :ok
    end

    private

    def error_rate_signal
      ratio = @metrics.failure_ratio
      status = if ratio >= 0.10 then :crit elsif ratio >= 0.02 then :warn else :ok end
      Signal.new(key: "error_rate", label: "Error rate (lifetime)", status: status,
                 detail: "#{(ratio * 100).round(1)}% of processed jobs have failed")
    end

    def latency_signal
      worst = @queues.max_by(&:latency)
      return Signal.new(key: "latency", label: "Queue latency", status: :ok, detail: "no active queues") if worst.nil?

      lat = worst.latency
      status = if lat > 600 then :crit elsif lat > 60 then :warn else :ok end
      detail = status == :ok ? "all queues fresh (< 60s)" : "#{worst.name}: oldest job #{RoundhouseUi.duration(lat)}"
      Signal.new(key: "latency", label: "Queue latency", status: status, detail: detail)
    end

    # A fully-busy fleet is what you want. It is only a problem when the work is
    # also backing up — so this used to cry wolf: a healthy app running flat out
    # reported Critical, and an alarm that fires when nothing is wrong is how
    # people learn to ignore the banner.
    #
    # What makes saturation bad is that it is *sustained*, and queue latency is
    # already the memory of that: if you have been at capacity long enough to
    # matter, the oldest job is old. So a momentary spike stays a warning and
    # only saturation with a backlog behind it escalates — no stored history
    # needed to tell them apart.
    SATURATED = 1.0
    BUSY = 0.85

    def utilization_signal
      util = @metrics.utilization
      return nil if util.nil? # no processes reporting in — can't judge

      pct = "#{(util * 100).round}% of worker threads busy"
      return Signal.new(key: "utilization", label: "Worker utilization", status: :ok, detail: pct) if util < BUSY
      return Signal.new(key: "utilization", label: "Worker utilization", status: :warn, detail: pct) if util < SATURATED

      if falling_behind?
        Signal.new(key: "utilization", label: "Worker utilization", status: :crit,
                   detail: "#{pct} and queues are falling behind")
      else
        Signal.new(key: "utilization", label: "Worker utilization", status: :warn,
                   detail: "#{pct} — at capacity, keeping up")
      end
    end

    # Saturation is only critical alongside a queue that is not being kept up
    # with, which is the same threshold the latency signal escalates on.
    def falling_behind?
      worst = @queues.max_by { |q| q.latency.to_f }
      worst && worst.latency.to_f > 60
    end
  end
end
