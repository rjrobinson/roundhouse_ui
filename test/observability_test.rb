require "test_helper"
require "cgi"

module RoundhouseUi
  # Every term here is asserted in its CGI-escaped form. traces_url escapes the
  # joined query per character, so an escaped term is a byte-exact substring of
  # the final URL — and asserting the raw form would pass on a URL that never
  # contained the term at all.
  class ObservabilityTest < ActiveSupport::TestCase
    def test_null_adapter_returns_no_links
      adapter = Observability::NullAdapter.new
      assert_nil adapter.job_url(klass: "X", jid: "1", queue: "default")
      assert_nil adapter.queue_url("default")
      assert_nil adapter.error_url(klass: "X", error: "Boom")
    end

    def test_datadog_adapter_builds_a_class_search_for_grouped_errors
      adapter = Observability::DatadogAdapter.new(service: "sidekiq")
      url = adapter.error_url(klass: "BulkImportJob", error: "PG::Error")

      assert_includes url, "app.datadoghq.com/apm/traces"
      assert_includes url, CGI.escape('resource_name:"BulkImportJob"')
      assert_includes url, CGI.escape("service:sidekiq")
    end

    # ":" is a Datadog query operator, so an unquoted namespaced class does not
    # merely fail to match — the query fails to parse. Every other fixture in
    # this file is flat, which is how that shipped unnoticed.
    def test_datadog_adapter_quotes_a_namespaced_class
      adapter = Observability::DatadogAdapter.new
      url = adapter.error_url(klass: "ActionMailer::MailDeliveryJob")

      assert_includes url, CGI.escape('resource_name:"ActionMailer::MailDeliveryJob"')
    end

    def test_datadog_adapter_builds_a_trace_url_from_the_jid
      adapter = Observability::DatadogAdapter.new(service: "sidekiq")
      url = adapter.job_url(klass: "ChargeJob", jid: "abc123")

      assert_includes url, "app.datadoghq.com/apm/traces"
      assert_includes url, CGI.escape('@sidekiq.job.id:"abc123"')
      assert_includes url, CGI.escape("service:sidekiq")
    end

    # The same JID is on the enqueueing push span, which can carry a different
    # service. Asserted in full: a bare "sidekiq.job" check would pass on the
    # substring inside %40sidekiq.job.id even with the term missing.
    def test_datadog_adapter_pins_the_job_span
      adapter = Observability::DatadogAdapter.new
      assert_includes adapter.job_url(klass: "ChargeJob", jid: "abc123"),
        CGI.escape("operation_name:sidekiq.job")
    end

    def test_datadog_adapter_builds_a_queue_search
      adapter = Observability::DatadogAdapter.new
      assert_includes adapter.queue_url("low"), CGI.escape('@sidekiq.job.queue:"low"')
    end

    # dd-trace records no such facets. Guarding explicitly because the failure is
    # silent — a wrong tag name returns an empty result set, not an error.
    def test_datadog_adapter_does_not_emit_facets_datadog_never_records
      adapter = Observability::DatadogAdapter.new
      refute_includes adapter.job_url(klass: "ChargeJob", jid: "abc123"), CGI.escape("@sidekiq.jid:")
      refute_includes adapter.queue_url("low"), CGI.escape("@sidekiq.queue:")
    end

    # The term is omitted rather than emitted empty — an operator who doesn't
    # know their Sidekiq service name is better served by a broad match.
    def test_datadog_adapter_omits_service_when_unset
      adapter = Observability::DatadogAdapter.new
      refute_includes adapter.job_url(klass: "ChargeJob", jid: "abc123"), CGI.escape("service:")
    end

    def test_datadog_adapter_honors_custom_site
      adapter = Observability::DatadogAdapter.new(site: "datadoghq.eu")
      assert_includes adapter.queue_url("low"), "app.datadoghq.eu/apm/traces"
    end
  end
end

module RoundhouseUi
  # Four entry points, one appearance. They were four hand-rolled copies and only
  # some got updated — two still emitted a literal ↗ after the rest moved to SVG.
  class ObservabilityConsistencyTest < ActionDispatch::IntegrationTest
    def setup
      RoundhouseUi.observability =
        RoundhouseUi::Observability::DatadogAdapter.new(site: "datadoghq.com", service: "sidekiq")
    end

    def teardown = RoundhouseUi.observability = RoundhouseUi::Observability::NullAdapter.new

    def view
      v = ActionController::Base.new.view_context
      v.extend(RoundhouseUi::ObservabilityHelper)
      v.extend(RoundhouseUi::ApplicationHelper)
      v
    end

    def all_affordances
      v = view
      [ v.trace_link(klass: "W", jid: "abc123"),
        v.trace_icon(klass: "W", jid: "abc123"),
        v.error_trace_link(klass: "W", error: "Boom"),
        v.error_trace_icon(klass: "W", error: "Boom") ]
    end

    def test_every_affordance_uses_the_same_glyph
      all_affordances.each_with_index do |html, i|
        assert_includes html, "<svg", "affordance #{i} did not render the shared glyph"
      end
    end

    # The character these replaced renders differently per platform, which is why
    # it went away everywhere else.
    def test_no_affordance_falls_back_to_a_unicode_arrow
      all_affordances.each_with_index do |html, i|
        refute_includes html, "↗", "affordance #{i} still emits a literal arrow"
      end
    end

    # They open a third-party page in a new tab, so none may hand it a
    # window.opener handle back into the console.
    def test_every_affordance_opens_safely
      all_affordances.each_with_index do |html, i|
        assert_includes html, 'rel="noopener noreferrer"', "affordance #{i} is missing rel"
        assert_includes html, 'target="_blank"', "affordance #{i} is missing target"
      end
    end

    # Two contexts by design now, and the rule is repetition: a row in a dense
    # list gets a control, a single item gets the vendor's mark. This replaced an
    # equality assertion, because collapsing them put 366 copies of someone
    # else's logo down one column.
    def test_a_row_gets_a_control_and_a_single_item_gets_the_mark
      v = view
      control = v.trace_icon(klass: "W", jid: "a")
      inline  = v.trace_link(klass: "W", jid: "a")

      assert_includes control, "rh-trace-btn"
      refute_includes control, "rh-mark-dd", "a row must not repeat the vendor mark"

      assert_includes inline, "rh-trace-mark"
      assert_includes inline, "rh-mark-dd"
      refute_includes inline, "rh-trace-btn"
    end

    # Both error surfaces follow the same rule as the job ones.
    def test_the_error_surfaces_split_the_same_way
      v = view
      assert_includes v.error_trace_icon(klass: "W", error: "B"), "rh-trace-btn"
      assert_includes v.error_trace_link(klass: "W", error: "B"), "rh-mark-dd"
    end

    # Datadog's rules forbid boxing the logo, and the row control is a box. So
    # the box may never contain the mark, whatever else changes.
    def test_the_boxed_control_never_contains_a_vendor_mark
      html = view.trace_icon(klass: "W", jid: "a")

      assert_includes html, "rh-trace-btn"
      refute_includes html, "<svg xmlns", "the vendor asset must not be boxed"
    end

    # Grouped Errors put the control inline in a text cell beside a .rh-runbook
    # pill, so it takes the row scale; an Actions-column control takes the page
    # scale and matches the buttons next to it. Both come from the same tokens.
    def test_the_inline_control_is_sized_for_a_text_cell
      assert_includes view.error_trace_icon(klass: "W", error: "B"), "rh-btn--sm"
      refute_includes view.trace_icon(klass: "W", jid: "a"), "rh-btn--sm",
        "an Actions-column control takes the page scale, not the row scale"
    end

    # The control owns its own box now, and so does every other control: one rule
    # on the --ctl-* tokens. Borrowing a sibling's class was the previous fix and
    # it still left two definitions to keep in step.
    def test_the_control_is_one_class_on_the_shared_scale
      # It used to be emitted as "rh-btn rh-trace-btn" / "rh-runbook rh-trace-btn
      # is-compact", borrowing another control's box because it had no box of its
      # own. Under the control scale it has one, from the same tokens as the rest.
      row = view.trace_icon(klass: "W", jid: "a")
      compact = view.error_trace_icon(klass: "W", error: "B")

      assert_includes row, "rh-trace-btn"
      refute_includes row, "rh-btn ", "still borrowing another control's box"
      assert_includes compact, "rh-btn--sm", "the compact variant must ask for the row scale"
      refute_includes compact, "rh-runbook", "still borrowing the runbook pill's box"
      refute_includes compact, "is-compact", "is-compact was the hand-rolled size; use the scale"
    end

    # The row glyph says nothing on its own, so a table has to name the target
    # once. With a plain adapter the rows already carry its label, so hoisting it
    # would just repeat what is already there.
    def test_the_legend_names_the_target_only_where_rows_cannot
      assert_includes view.trace_legend([ :a_row ]), "Traces open in"
      assert_includes view.trace_legend([ :a_row ]), "rh-mark-dd"

      plain = Class.new do
        def label = "Honeycomb"
        def job_url(**) = "https://example.test/t"
      end
      RoundhouseUi.observability = plain.new
      assert_nil view.trace_legend([ :a_row ])
    end

    # A configured adapter that returns no URL must not leave a legend pointing
    # nowhere above an otherwise fine table.
    def test_no_legend_when_the_adapter_yields_no_urls
      RoundhouseUi.observability = RoundhouseUi::Observability::NullAdapter.new
      assert_nil view.trace_legend([ :a_row ])
    end

    # The legend describes a per-row control. Above an empty table it explains
    # something that is not on the page — "Traces open in Datadog" sitting over
    # "Nothing scheduled", which is how this was found.
    def test_no_legend_above_an_empty_table
      assert_nil view.trace_legend([])
      assert_nil view.trace_legend(nil)
    end

    # The mark spells "Datadog" itself, so printing the label beside it renders
    # "Datadog Datadog". Asserting on the span, not the bare word — the word is
    # also in the title and aria-label, where it belongs.
    def test_a_wordmark_adapter_does_not_repeat_its_own_name
      html = view.trace_link(klass: "W", jid: "a")

      assert_includes html, "rh-trace-mark"
      assert_includes html, "rh-mark-dd"
      refute_includes html, "<span>Datadog</span>"
      assert_includes html, 'aria-label="Open in Datadog"'
    end

    # A legend on a page whose rows have no trace control explains a glyph that
    # is not there. Busy had one for exactly that reason.
    def test_only_pages_with_a_row_control_carry_a_legend
      views = Dir[RoundhouseUi::Engine.root.join("app/views/roundhouse_ui/*/index.html.erb")]
      refute_empty views

      views.each do |path|
        body = File.read(path)
        next unless body.include?("trace_legend")

        assert_includes body, "trace_icon",
          "#{File.basename(File.dirname(path))} has a legend but no row control to explain"
      end
    end

    # An adapter with no mark of its own keeps the name; a bare arrow says
    # nothing about where it goes.
    def test_an_adapter_without_a_wordmark_keeps_its_label
      plain = Class.new do
        def label = "Honeycomb"
        def job_url(**) = "https://example.test/trace"
      end
      RoundhouseUi.observability = plain.new

      html = view.trace_link(klass: "W", jid: "a")
      assert_includes html, "<span>Honeycomb</span>"
      refute_includes html, "rh-trace-mark"
    end

    # Datadog's white lockup is different artwork, not the purple one recoloured.
    # Shipping one and forcing the fill is what rendered Bits as a solid tile
    # with the dog knocked out of him.
    def test_both_lockup_variants_ship_and_are_distinct_artwork
      light = Observability::DatadogAdapter::MARK_ON_LIGHT
      dark  = Observability::DatadogAdapter::MARK_ON_DARK

      assert_includes light, "0 0 800.5 203.19"
      assert_includes dark,  "0 0 800.5 196.2"
      refute_equal light.scan(/<(?:path|polygon)/).size, 0
      refute_equal light[/d="([^"]+)"/, 1], dark[/d="([^"]+)"/, 1],
        "the two variants must be different artwork, not one recoloured"
    end

    # The exact defect: blanket-applying evenodd to the white asset closes voids
    # that its .st0 class deliberately leaves open. If every element carries
    # evenodd, the conversion flattened Datadog's own fill rules.
    def test_the_white_lockup_keeps_its_nonzero_elements
      dark = Observability::DatadogAdapter::MARK_ON_DARK
      shapes = dark.scan(/<(?:path|polygon)\b[^>]*>/)

      refute_empty shapes
      assert shapes.any? { |el| !el.include?("fill-rule") },
        "at least one element must keep the default nonzero rule"
      assert shapes.any? { |el| el.include?('fill-rule="evenodd"') },
        "and at least one must keep evenodd"
    end

    # An inline <style> inside the SVG would need a nonce the adapter cannot see,
    # so under default-src 'none' the mark would render unfilled.
    def test_neither_lockup_carries_css_the_csp_would_block
      [ Observability::DatadogAdapter::MARK_ON_LIGHT,
        Observability::DatadogAdapter::MARK_ON_DARK ].each do |svg|
        refute_includes svg, "<style"
        refute_match(/class="st\d"/, svg, "an unconverted Illustrator class renders unfilled")
      end
    end

    # The mark appears in more than one container — inline in a link, and in the
    # legend above a table. Scoping its rules under a parent affordance class
    # meant the legend matched none of them and drew both variants at full size,
    # so the selectors must stay unscoped.
    def test_the_mark_rules_are_not_scoped_to_one_container
      css = File.read(RoundhouseUi::Engine.root.join("app/views/layouts/roundhouse_ui/application.html.erb"))

      assert_includes css, ".rh-mark-on-light { display:block; }"
      assert_includes css, ".rh-mark-on-dark { display:none; }"
      assert_includes css, "@media (prefers-color-scheme: dark)"
      assert_match(/^\s*\.rh-mark-dd \{[^}]*height:/, css, "the mark must size itself anywhere")

      css.scan(/^\s*([^\n{]*\.rh-mark-on-(?:light|dark))\s*\{[^}]*display:/).flatten.each do |sel|
        sel = sel.strip
        next if sel.start_with?(":root")
        assert_equal 1, sel.split.size,
          "#{sel} confines a display rule to one container; the mark renders in several"
      end
    end

    # Datadog's usage rules forbid encasing the logo in a box or shape, and the
    # affordance this replaced was a 24px bordered square.
    def test_a_vendor_mark_is_never_boxed
      css = File.read(RoundhouseUi::Engine.root.join("app/views/layouts/roundhouse_ui/application.html.erb"))
      rule = css[/^\s*\.rh-trace-mark \{([^}]*)\}/, 1]

      assert rule, "expected a .rh-trace-mark rule"
      refute_match(/\bborder\b|\bbackground\b/, rule, "a vendor mark must not be encased")
    end

    # An adapter with no error_url must not raise on the error surfaces.
    def test_an_adapter_without_error_urls_renders_nothing_there
      RoundhouseUi.observability = RoundhouseUi::Observability::NullAdapter.new
      assert_nil view.error_trace_icon(klass: "W", error: "Boom")
    end
  end
end
