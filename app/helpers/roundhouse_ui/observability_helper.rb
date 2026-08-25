module RoundhouseUi
  # Links out to whatever APM the host configured. Four entry points — job or
  # error, icon-only or labelled — but one appearance, because they turned into
  # four hand-rolled copies and only some of them got updated: two still emitted
  # a literal ↗ character after the rest moved to SVG.
  module ObservabilityHelper
    def trace_link(klass:, jid:, queue: nil)
      trace_affordance(job_trace_url(klass: klass, jid: jid, queue: queue), labelled: true)
    end

    def trace_icon(klass:, jid:, queue: nil)
      trace_affordance(job_trace_url(klass: klass, jid: jid, queue: queue))
    end

    def error_trace_link(klass:, error: nil)
      trace_affordance(error_trace_url(klass: klass, error: error), labelled: true)
    end

    def error_trace_icon(klass:, error: nil)
      trace_affordance(error_trace_url(klass: klass, error: error))
    end

    # An adapter's own mark, when it supplies one. Three shapes are accepted, in
    # descending order of how much we trust them:
    #
    #   :name      → one of Roundhouse's shipped icons
    #   "<svg …>"  → the adapter's markup, rendered as-is
    #   nil        → the default trace glyph
    #
    # The markup case is not escaped, because escaping renders the tags as text
    # and the feature does not work at all. That is the same trust level as the
    # adapter object itself, which can already run arbitrary code. Anything that
    # is neither markup nor a known name falls back rather than printing stray
    # text into a table.
    def trace_glyph(adapter)
      supplied = adapter.respond_to?(:icon) ? adapter.icon : nil
      return icon(:trace_out) if supplied.blank?
      return icon(supplied) if supplied.is_a?(Symbol)

      supplied.to_s.strip.start_with?("<") ? supplied.to_s.html_safe : icon(:trace_out)
    end

    private

    def job_trace_url(klass:, jid:, queue: nil)
      RoundhouseUi.observability.job_url(klass: klass, jid: jid, queue: queue)
    end

    def error_trace_url(klass:, error: nil)
      adapter = RoundhouseUi.observability
      return nil unless adapter.respond_to?(:error_url)

      adapter.error_url(klass: klass, error: error)
    end

    # One appearance for every trace affordance on every page. `labelled` adds the
    # adapter's name where there is room for it; the glyph is identical either way.
    def trace_affordance(url, labelled: false)
      return nil if url.blank?

      adapter = RoundhouseUi.observability
      glyph = trace_glyph(adapter)
      body = labelled ? safe_join([ glyph, content_tag(:span, adapter.label) ]) : glyph

      link_to body, url, target: "_blank", rel: "noopener noreferrer",
        class: "rh-trace#{' rh-trace-ico' unless labelled}",
        title: "Open in #{adapter.label}",
        aria: { label: "Open in #{adapter.label}" }
    end
  end
end
