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
  # Write your own (Honeycomb, Sentry, …) by duck-typing job_url and label.
  # error_url, icon and wordmark? are optional; queue_url is unused by the UI.
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

      # Datadog's official horizontal lockup, from datadoghq.com/about/resources
      # (Logo_Assets.zip). Their mark, their trademark, shipped unmodified in
      # geometry and aspect ratio.
      #
      # Both variants ship, because Datadog's white lockup is different artwork
      # rather than the purple one recoloured: a different viewBox (196.2 tall
      # against 203.19) and a different fill-rule mix. Forcing white onto the
      # purple paths renders Bits as a solid tile with the dog knocked out of
      # him. The only edit is moving their <style> block's declarations onto the
      # elements that carried each class — per element, since the white asset
      # mixes nonzero and evenodd — because an inline <style> inside the SVG
      # would need a CSP nonce an adapter cannot see.
      #
      # The lockup rather than the icon-only mark, because Bits is drawn for
      # large use: at the 12-16px a table row allows he renders as a smudge,
      # while the wordmark stays legible to about 11px.
      MARKS_DIR = File.expand_path("marks", __dir__)
      MARK_ON_LIGHT = File.read(File.join(MARKS_DIR, "datadog-lockup.svg")).freeze
      MARK_ON_DARK  = File.read(File.join(MARKS_DIR, "datadog-lockup-white.svg")).freeze

      # Both go in the markup and CSS picks one, rather than the UI guessing the
      # ground it will be painted on. A viewer on the system default has stamped
      # no theme at all, so there is nothing server-side to branch on.
      def icon = MARK_ON_LIGHT + MARK_ON_DARK

      # The mark already spells "Datadog", so the UI must not print the word
      # again beside it. Datadog's usage rules also forbid encasing the logo in
      # a box, which is why this affordance stays borderless where its sibling
      # controls do not.
      def wordmark? = true

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
