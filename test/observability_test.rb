require "test_helper"
require "cgi"

module RoundhouseUi
  class ObservabilityTest < ActiveSupport::TestCase
    def test_null_adapter_returns_no_links
      adapter = Observability::NullAdapter.new
      assert_nil adapter.job_url(klass: "X", jid: "1", queue: "default")
      assert_nil adapter.queue_url("default")
    end

    def test_datadog_adapter_builds_a_trace_url_from_the_jid
      adapter = Observability::DatadogAdapter.new(service: "trainual")
      url = adapter.job_url(klass: "ChargeJob", jid: "abc123")

      assert_includes url, "app.datadoghq.com/apm/traces"
      assert_includes url, CGI.escape("@sidekiq.jid:abc123")
      assert_includes url, CGI.escape("service:trainual")
    end

    def test_datadog_adapter_honors_custom_site
      adapter = Observability::DatadogAdapter.new(site: "datadoghq.eu")
      assert_includes adapter.queue_url("low"), "app.datadoghq.eu/apm/traces"
    end
  end
end
