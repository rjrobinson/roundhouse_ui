module RoundhouseUi
  # Resolves a runbook for a job class at read time, the same way Tags resolves
  # owners (ADR 0002) — no middleware, no storage, applies retroactively to jobs
  # already in the sets.
  #
  #   RoundhouseUi.job_runbooks = RoundhouseUi::Runbooks.from_constant(:RUNBOOK)
  #   RoundhouseUi.job_runbooks = { "Billing::SyncWorker" => "https://wiki/…" }
  #   RoundhouseUi.job_runbooks = ->(klass:, item:) { "https://wiki/#{klass}" }
  #
  # Whoever wrote the job knows what to do when it fails; the person paged at
  # 3am usually does not. This is the cheapest possible bridge between them.
  module Runbooks
    module_function

    # A runbook URL for one job, or nil. Resolvers always see the real job
    # class — the ActiveJob wrapper is unwrapped first, so a runbook declared on
    # a mailer is found when that mailer fails.
    #
    # Only http(s) URLs are returned. A runbook lands in an href, so `javascript:`
    # and `data:` are refused rather than escaped: a host that misconfigures this
    # should get no link, not a link that runs.
    def for(klass, item = nil, cache: nil)
      source = RoundhouseUi.job_runbooks
      return nil unless source

      effective = RoundhouseUi.unwrapped_class(klass, item)
      return nil unless effective.present?
      return resolve(source, effective, item) unless cache

      # `item` is withheld once we are caching by class — the same rule Tags
      # follows, and for the same reason: a resolver that reads the payload but
      # is cached per class would hand every job of that class the *first* job's
      # runbook. Withholding makes that misuse resolve to nil deterministically
      # instead of returning something plausible and wrong. A runbook describes a
      # job class, so reading the payload is a misuse rather than a use case.
      cache.key?(effective) ? cache[effective] : cache[effective] = resolve(source, effective, nil)
    end

    # The class-constant convention, matching Tags.from_constant. Inherited
    # constants count, so a base class can carry the runbook for a whole family.
    def from_constant(const_name = :RUNBOOK)
      lambda do |klass:, item:|
        _ = item
        k = RoundhouseUi.job_class(klass)
        k.const_get(const_name) if k&.const_defined?(const_name)
      end
    end

    # -- internals ----------------------------------------------------------

    def resolve(source, klass, item)
      raw = if source.respond_to?(:call)
              source.call(klass: klass, item: item)
      elsif source.respond_to?(:[])
              source[klass]
      end
      safe_url(raw)
    rescue StandardError => e
      warn_once("job_runbooks resolver failed for #{klass}: #{e.message}")
      nil
    end

    def safe_url(raw)
      url = raw.to_s.strip
      # Capped like theme values are: this is interpolated into markup on every
      # matching row, and a runaway string from a misconfigured resolver should
      # not become the page.
      return nil if url.empty? || url.length > 2_000

      url if url.match?(%r{\Ahttps?://\S+\z}i)
    end

    def warn_once(message)
      Rails.logger&.warn("[roundhouse] #{message}") if defined?(Rails)
    end
  end
end
