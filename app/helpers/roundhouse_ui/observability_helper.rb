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
    # An adapter's own mark, when it has one. Three shapes are accepted, in
    # descending order of how much we trust them:
    #
    #   :name      → one of Roundhouse's own shipped icons
    #   "<svg …>"  → the adapter's markup, rendered as-is
    #   nil        → the default trace glyph
    #
    # The markup case is deliberately not escaped, because escaping it would
    # render the tags as text and the feature would not work at all. That makes
    # it the adapter author's responsibility, which is the same trust level as
    # any other object a host assigns to RoundhouseUi.observability — it can
    # already run arbitrary code.
    def trace_glyph(adapter)
      supplied = adapter.respond_to?(:icon) ? adapter.icon : nil
      return icon(:trace_out) if supplied.blank?
      return icon(supplied) if supplied.is_a?(Symbol)

      supplied.to_s.strip.start_with?("<") ? supplied.to_s.html_safe : icon(:trace_out)
    end

    def trace_icon(klass:, jid:, queue: nil)
      adapter = RoundhouseUi.observability
      url = adapter.job_url(klass: klass, jid: jid, queue: queue)
      return unless url

      link_to trace_glyph(adapter), url, target: "_blank", rel: "noopener",
        class: "rh-trace rh-trace-ico",
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
