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
