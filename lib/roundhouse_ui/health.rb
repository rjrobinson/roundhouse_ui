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
      detail = status == :ok ? "all queues fresh (< 60s)" : "#{worst.name}: oldest job #{lat.round}s"
      Signal.new(key: "latency", label: "Queue latency", status: status, detail: detail)
    end

    def utilization_signal
      util = @metrics.utilization
      return nil if util.nil? # no processes reporting in — can't judge

      status = if util >= 1.0 then :crit elsif util >= 0.85 then :warn else :ok end
      Signal.new(key: "utilization", label: "Worker utilization", status: status,
                 detail: "#{(util * 100).round}% of worker threads busy")
    end
  end
end
