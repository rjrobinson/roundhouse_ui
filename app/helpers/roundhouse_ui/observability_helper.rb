module RoundhouseUi
  # Links out to whatever APM the host configured. Four entry points — job or
  # error, by historical call-site name — and exactly one appearance. They were
  # four hand-rolled copies once, and only some got updated: two still emitted a
  # literal ↗ after the rest moved to SVG. Later the split survived as two
  # different shapes, a text link and a bordered box, which is not "one
  # appearance" however the helper described itself.
  module ObservabilityHelper
    def trace_link(klass:, jid:, queue: nil)
      trace_affordance(job_trace_url(klass: klass, jid: jid, queue: queue), as: :mark)
    end

    def trace_icon(klass:, jid:, queue: nil)
      trace_affordance(job_trace_url(klass: klass, jid: jid, queue: queue), as: :control)
    end

    def error_trace_link(klass:, error: nil)
      trace_affordance(error_trace_url(klass: klass, error: error), as: :mark)
    end

    def error_trace_icon(klass:, error: nil)
      trace_affordance(error_trace_url(klass: klass, error: error), as: :control, compact: true)
    end

    # Says once, above a table, where every row's trace glyph goes. Takes the rows
    # it is describing, because a legend above an empty table explains a control
    # that is not on the page — which is exactly what "Nothing scheduled" under
    # "Traces open in Datadog" looked like.
    #
    # Returns nil unless the adapter has a mark of its own, too: a plain adapter
    # already labels every row, so there would be nothing to hoist.
    def trace_legend(rows)
      return nil if rows.blank?

      adapter = RoundhouseUi.observability
      return nil unless wordmark?(adapter)
      return nil if adapter.job_url(klass: "Probe", jid: "probe").blank?

      content_tag(:div, class: "rh-trace-legend") do
        safe_join([ content_tag(:span, "Traces open in"), trace_glyph(adapter) ], " ")
      end
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

    # Two contexts, one principle: a dense list gets a control, a single item
    # gets the vendor's mark.
    #
    # In a table the mark would repeat on every row — 366 copies of someone
    # else's logo on one Retries page, and the only unboxed thing in a column of
    # bordered buttons. So rows get a Roundhouse glyph shaped exactly like the
    # buttons beside it, and the page says once, above the table, where that
    # glyph goes. On a page showing one job there is nothing to tile, so the
    # mark itself goes inline where it has room to read.
    #
    # This is not the old `labelled` split, which was two arbitrary shapes with
    # no stated rule. The distinction here is repetition, and `trace_legend` is
    # what makes the row glyph legible without restating the brand per row.
    def trace_affordance(url, as:, compact: false)
      return nil if url.blank?

      adapter = RoundhouseUi.observability
      return trace_control(url, adapter, compact: compact) if as == :control

      link_to trace_body(adapter), url, **trace_attrs(adapter),
        class: "rh-trace#{' rh-trace-mark' if wordmark?(adapter)}"
    end

    # Shaped like whatever it sits beside. In an Actions column that is .rh-btn,
    # so it lands level with Run now and Delete. Inline in a text cell it is
    # .rh-runbook's smaller pill, because a 28px-tall button next to an 11.5px
    # "runbook" link puts three different heights in one table cell.
    #
    # Never carries the vendor mark either way: boxing a logo is against most
    # brand guidelines, Datadog's included.
    def trace_control(url, adapter, compact: false)
      # .rh-btn itself, not a copy of its measurements. A second box definition
      # drifted by 2px the moment .rh-btn's font-size and padding were the source
      # of truth and .rh-trace-btn's hard-coded height was not.
      base = compact ? "rh-runbook rh-trace-btn is-compact" : "rh-btn rh-trace-btn"
      link_to icon(:trace_out), url, **trace_attrs(adapter), class: base
    end

    def trace_body(adapter)
      glyph = trace_glyph(adapter)
      return glyph if wordmark?(adapter)

      safe_join([ glyph, content_tag(:span, adapter.label) ])
    end

    def trace_attrs(adapter)
      { target: "_blank", rel: "noopener noreferrer",
        title: "Open in #{adapter.label}",
        aria: { label: "Open in #{adapter.label}" } }
    end

    def wordmark?(adapter)
      adapter.respond_to?(:wordmark?) && adapter.wordmark?
    end
  end
end
