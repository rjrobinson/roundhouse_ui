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
  # An adapter can supply its own mark. Roundhouse ships no vendor logo: a
  # trademark in this gem's files is the host's problem to opt into, not ours to
  # bundle.
  class ObservabilityIconTest < ActionDispatch::IntegrationTest
    def teardown = RoundhouseUi.observability = RoundhouseUi::Observability::NullAdapter.new

    class WithSvg
      def label = "Acme"
      def icon = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/></svg>'
      def job_url(**) = "https://acme.test/t"
      def queue_url(*) = nil
      def error_url(**) = nil
    end

    class WithNamed
      def label = "Named"
      def icon = :redis
      def job_url(**) = "https://named.test/t"
      def queue_url(*) = nil
      def error_url(**) = nil
    end

    class WithJunk
      def label = "Junk"
      def icon = "not markup and not a name"
      def job_url(**) = "https://junk.test/t"
      def queue_url(*) = nil
      def error_url(**) = nil
    end

    # An adapter predating this feature has no #icon at all and must still work.
    class Legacy
      def label = "Legacy"
      def job_url(**) = "https://legacy.test/t"
      def queue_url(*) = nil
      def error_url(**) = nil
    end

    def glyph_for(adapter)
      RoundhouseUi.observability = adapter
      view = ActionController::Base.new.view_context
      view.extend(RoundhouseUi::ObservabilityHelper)
      view.extend(RoundhouseUi::ApplicationHelper)
      view.trace_glyph(adapter)
    end

    def test_supplied_markup_is_rendered_rather_than_escaped
      html = glyph_for(WithSvg.new)
      assert_includes html, "<circle"
      refute_includes html, "&lt;svg"
    end

    def test_a_symbol_resolves_to_a_shipped_icon
      assert_includes glyph_for(WithNamed.new), "<svg"
    end

    # A string that is neither markup nor a name would otherwise render as stray
    # text in the middle of a table.
    def test_junk_falls_back_to_the_default_glyph
      html = glyph_for(WithJunk.new)
      assert_includes html, "<svg"
      refute_includes html, "not markup"
    end

    def test_an_adapter_without_an_icon_method_still_renders
      assert_includes glyph_for(Legacy.new), "<svg"
    end

    # The shipped Datadog adapter must not carry Datadog's logo.
    def test_no_vendor_mark_ships
      assert_nil RoundhouseUi::Observability::DatadogAdapter.new.icon
      assert_includes glyph_for(RoundhouseUi::Observability::DatadogAdapter.new(site: "x")), "<svg"
    end

    def test_a_host_can_pass_one_in
      adapter = RoundhouseUi::Observability::DatadogAdapter.new(icon: "<svg><rect/></svg>")
      assert_includes glyph_for(adapter), "<rect"
    end
  end
end
