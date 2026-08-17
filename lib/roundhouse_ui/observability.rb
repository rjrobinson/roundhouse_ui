require "cgi"

module RoundhouseUi
  # Pluggable deep-links from a job to your APM/observability tool. The core
  # never depends on Datadog (or anything) — it asks the configured adapter for
  # a URL and renders a link only if one comes back.
  #
  #   RoundhouseUi.observability = RoundhouseUi::Observability::DatadogAdapter.new(service: "sidekiq")
  #
  # `service:` is the service your *Sidekiq spans* carry, which is frequently not
  # your app name — apps commonly set `c.tracing.instrument :sidekiq, service_name:
  # "sidekiq"`, and dd-trace has no default of its own. Passing the app name when
  # your spans say something else silently matches nothing. Omit it if unsure; the
  # term is left out entirely when nil.
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

      # Tag names come from dd-trace-rb's Sidekiq integration: sidekiq.job.id and
      # sidekiq.job.queue (Datadog::Tracing::Contrib::Sidekiq::Ext). There is no
      # `sidekiq.jid` or `sidekiq.queue` facet — querying those matches nothing.
      #
      # operation_name pins the job span: a JID also appears on the enqueueing
      # push span, and the two can sit under different service names.
      #
      # Values are quoted because ":" is a Datadog query operator — an unquoted
      # namespaced class is not merely unmatched, it fails to parse.
      def job_url(klass:, jid:, queue: nil)
        terms = [ %(@sidekiq.job.id:"#{jid}"), "operation_name:sidekiq.job" ]
        terms << "service:#{@service}" if @service
        terms << @extra_query if @extra_query
        traces_url(terms)
      end

      def queue_url(name)
        traces_url([ %(@sidekiq.job.queue:"#{name}") ])
      end

      # Grouped Errors rows have no single JID, so link to a class-wide search.
      # dd-trace sets span.resource to the job class — unwrapped, for ActiveJob —
      # so callers must pass the real class, not the adapter's wrapper. Tune via
      # `extra_query` if your spans are tagged differently.
      def error_url(klass:, error: nil)
        terms = [ %(resource_name:"#{klass}") ]
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
