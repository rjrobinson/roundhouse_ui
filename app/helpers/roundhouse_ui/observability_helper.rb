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

    # Icon-only variant for table rows. The adapter's name is worth reading once
    # in a header or a detail page, not once per row — there it is width spent
    # repeating a word the operator already knows.
    def trace_icon(klass:, jid:, queue: nil)
      adapter = RoundhouseUi.observability
      url = adapter.job_url(klass: klass, jid: jid, queue: queue)
      return unless url

      link_to "↗", url, target: "_blank", rel: "noopener", class: "rh-trace rh-trace-ico",
        title: "Open in #{adapter.label}", "aria-label": "Open in #{adapter.label}"
    end

    def error_trace_icon(klass:, error: nil)
      adapter = RoundhouseUi.observability
      return unless adapter.respond_to?(:error_url)

      url = adapter.error_url(klass: klass, error: error)
      return unless url

      link_to "↗", url, target: "_blank", rel: "noopener", class: "rh-trace rh-trace-ico",
        title: "Open in #{adapter.label}", "aria-label": "Open in #{adapter.label}"
    end

    # Deep-link for a grouped error row (no single JID) — a class-wide search.
    # respond_to? keeps older/custom adapters that lack error_url working.
    def error_trace_link(klass:, error: nil)
      adapter = RoundhouseUi.observability
      return unless adapter.respond_to?(:error_url)

      url = adapter.error_url(klass: klass, error: error)
      return unless url

      link_to "↗ #{adapter.label}", url, target: "_blank", rel: "noopener", class: "rh-trace"
    end
  end
end
