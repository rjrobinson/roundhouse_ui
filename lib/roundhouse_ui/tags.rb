module RoundhouseUi
  # Resolves host-defined tags for a job at read time (no middleware, no
  # storage — works on every backend and applies retroactively to jobs already
  # in the sets). The host supplies the resolver; see ADR 0002.
  #
  #   RoundhouseUi.job_tags = RoundhouseUi::Tags.from_constant(:OWNER, as: :squad)
  #   # or any callable:
  #   RoundhouseUi.job_tags = ->(klass:, item:) { { squad: :growth } }
  #
  # Contract: resolver output is normalized to string keys/values, masked via
  # Redaction (redact_args patterns apply to tag keys), and a raising resolver
  # yields no tags — tagging must never break a page.
  module Tags
    EMPTY = {}.freeze

    module_function

    # Tags for one job entry, as a { "key" => "value" } Hash (EMPTY when no
    # resolver is configured, the resolver declines, or it raises).
    #
    # `klass`/`item` come from the backend entry (entry.klass / entry.item);
    # the ActiveJob adapter wrapper is unwrapped here, so resolvers always see
    # the real job class. Pass a Hash as `cache` to memoize per class across a
    # request — unused (and unneeded) in per-job mode.
    def for(klass:, item:, cache: nil)
      resolver = RoundhouseUi.job_tags
      return EMPTY unless resolver

      effective = effective_klass(klass, item)
      return EMPTY unless effective

      if RoundhouseUi.job_tags_per_job
        # Per-job mode still memoizes, keyed by jid rather than class: a job's
        # tags cannot change within one request, and the same entry is resolved
        # twice otherwise — once while scanning, once when its badge renders.
        jid = item["jid"] if item.is_a?(Hash)
        return resolve(resolver, effective, item) unless cache && jid

        cache.key?(jid) ? cache[jid] : cache[jid] = resolve(resolver, effective, item)
      elsif cache
        # Class-cached mode: item is withheld (deliberately — see resolve).
        cache.key?(effective) ? cache[effective] : cache[effective] = resolve(resolver, effective, nil)
      else
        resolve(resolver, effective, nil)
      end
    end

    # The class-constant convention (Trainual's OWNER pattern) as a resolver:
    #
    #   RoundhouseUi.job_tags = RoundhouseUi::Tags.from_constant(:OWNER, as: :squad)
    #
    # Tags every job whose class (or ancestor — inherited constants count, so a
    # base-class OWNER covers subclasses) defines the constant.
    def from_constant(const_name, as: const_name.to_s.downcase)
      lambda do |klass:, item:|
        k = RoundhouseUi.job_class(klass)
        { as => k.const_get(const_name) } if k&.const_defined?(const_name)
      end
    end

    # The declared filter vocabulary, normalized to { "key" => ["value", ...] },
    # or nil when the host declared none (the filter UI then discovers values
    # from the entries it scans). Both the whole setting and individual values
    # may be callables, so vocabularies can be dynamic.
    def filters
      declared = RoundhouseUi.tag_filters
      declared = declared.call if declared.respond_to?(:call)
      return nil unless declared.is_a?(Hash)

      declared.each_with_object({}) do |(key, values), out|
        values = values.call if values.respond_to?(:call)
        out[key.to_s] = Array(values).map(&:to_s)
      end
    rescue => e
      warn_once("tag_filters failed: #{e.message}")
      nil
    end

    # Does a resolved tag Hash match a key/value filter? Exact match on the
    # normalized (post-redaction) value — so a redacted tag matches only its
    # mask, and the filter can't be used to probe redacted values.
    def match?(tags, key, value)
      tags[key.to_s] == value.to_s
    end

    # -- internals ----------------------------------------------------------

    # Resolvers always see the real job class. The unwrap now lives on
    # RoundhouseUi so search, grouping and APM links resolve to the identical
    # string — see RoundhouseUi.unwrapped_class.
    def effective_klass(klass, item)
      RoundhouseUi.unwrapped_class(klass, item)
    end

    # `item` is nil in class-cached mode: an args-reading resolver cached by
    # class would poison the cache with first-job-wins values — withholding the
    # payload makes it fail deterministically (rescued → no tags) instead.
    # Hosts that need the payload set RoundhouseUi.job_tags_per_job = true.
    def resolve(resolver, klass, item)
      tags = resolver.call(klass: klass, item: item)
      return EMPTY unless tags.is_a?(Hash)

      normalized = tags.each_with_object({}) { |(k, v), out| out[k.to_s] = v.to_s }
      Redaction.apply(normalized)
    rescue => e
      warn_once("job_tags resolver failed for #{klass}: #{e.message}")
      EMPTY
    end

    def warn_once(message)
      Rails.logger&.warn("[roundhouse] #{message}") if defined?(Rails)
    end
  end
end
