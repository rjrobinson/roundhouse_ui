module RoundhouseUi
  module ObservabilityHelper
    # Renders a deep-link to the configured observability tool for a job, or
    # nothing when no adapter is configured (the default).
    def trace_link(klass:, jid:, queue: nil)
      adapter = RoundhouseUi.observability
      url = adapter.job_url(klass: klass, jid: jid, queue: queue)
      return unless url

      link_to "↗ #{adapter.label}", url, target: "_blank", rel: "noopener", class: "rh-trace"
    end
  end
end
