require "cgi"

module RoundhouseUi
  # Pluggable deep-links from a job to your APM/observability tool. The core
  # never depends on Datadog (or anything) — it asks the configured adapter for
  # a URL and renders a link only if one comes back.
  #
  #   RoundhouseUi.observability = RoundhouseUi::Observability::DatadogAdapter.new(service: "trainual")
  #
  # Write your own (Honeycomb, Sentry, …) by duck-typing job_url/queue_url/label.
  module Observability
    # Default: no links anywhere.
    class NullAdapter
      def label = "trace"
      def job_url(**) = nil
      def queue_url(_name) = nil
      def error_url(**) = nil
    end

    class DatadogAdapter
      def initialize(site: "datadoghq.com", service: nil, extra_query: nil)
        @site = site
        @service = service
        @extra_query = extra_query
      end

      def label = "Datadog"

      def job_url(klass:, jid:, queue: nil)
        terms = [ "@sidekiq.jid:#{jid}" ]
        terms << "service:#{@service}" if @service
        terms << @extra_query if @extra_query
        traces_url(terms)
      end

      def queue_url(name)
        traces_url([ "@sidekiq.queue:#{name}" ])
      end

      # Grouped Errors rows have no single JID, so link to a class-wide search.
      # The exact facet depends on your Datadog tagging; tune via `extra_query`
      # if `resource_name` isn't how your Sidekiq spans are tagged.
      def error_url(klass:, error: nil)
        terms = [ "resource_name:#{klass}" ]
        terms << "service:#{@service}" if @service
        terms << @extra_query if @extra_query
        traces_url(terms)
      end

      private

      def traces_url(terms)
        "https://app.#{@site}/apm/traces?query=#{CGI.escape(terms.compact.join(" "))}"
      end
    end
  end
end
