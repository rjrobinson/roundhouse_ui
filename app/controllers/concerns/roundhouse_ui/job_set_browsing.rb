module RoundhouseUi
  # Shared search + pagination over a Sidekiq job set (dead, retry, scheduled).
  # Keeps the controllers from duplicating the scan/filter/window logic.
  module JobSetBrowsing
    extend ActiveSupport::Concern

    PER_PAGE = 25
    BULK_CAP = 1_000 # safety ceiling on a single match-set action

    # Returns [entries_for_page, has_next?]. Scans only far enough to fill the
    # requested page plus one (to know if a next page exists) — never loads the
    # whole set, so a 50k dead set stays cheap to page through.
    # `?tag=key:value` — an exact match against a host-defined tag (ADR 0002),
    # parsed once per request. Deliberately structured rather than folded into
    # the free-text query: substring search feeding bulk_apply would silently
    # widen destructive bulk actions.
    def tag_filter
      key, value = params[:tag].to_s.split(":", 2)
      return nil if key.blank? || value.blank?

      [ key, value ]
    end

    def browse(set, query, page, per = PER_PAGE, tag: nil)
      start = (page - 1) * per
      jobs = []
      has_next = false
      matched = 0
      cache = tag_cache_for(tag)

      set.each do |entry|
        next unless entry_selected?(entry, query, tag, cache)

        if matched < start
          matched += 1
        elsif jobs.size < per
          jobs << entry
          matched += 1
        else
          has_next = true
          break
        end
      end

      [ jobs, has_next ]
    end

    # Apply an op ("retry"/"delete") to every entry matching the query, capped at
    # BULK_CAP. Entries are collected first, then acted on — mutating a Sidekiq set
    # mid-iteration skips entries. Returns [count_acted_on, capped?].
    def bulk_apply(set, query, op, cap = BULK_CAP, tag: nil)
      matches = []
      capped = false
      cache = tag_cache_for(tag)
      set.each do |entry|
        next unless entry_selected?(entry, query, tag, cache)

        matches << entry
        if matches.size >= cap
          capped = true
          break
        end
      end
      matches.each { |entry| op == "delete" ? entry.delete : entry.retry }
      [ matches.size, capped ]
    end

    # Both the browse and bulk paths run every candidate through this, so the
    # rows an operator sees are exactly the rows a bulk action will touch.
    def entry_selected?(entry, query, tag, cache)
      return false if query.present? && !entry_matches?(entry, query)
      return true if tag.nil?

      entry_tagged?(entry, tag, cache)
    end

    def entry_tagged?(entry, (key, value), cache)
      # A declared vocabulary is authoritative: filtering on a key the host
      # never declared matches nothing rather than everything.
      declared = Tags.filters
      return false if declared && !declared.key?(key)

      Tags.match?(Tags.for(klass: entry.klass, item: entry.item, cache: cache), key, value)
    end

    # One memo per browse/bulk pass. Nil in per-job mode, where tags vary by
    # payload and caching by class would be wrong.
    def tag_cache_for(tag)
      tag && !RoundhouseUi.job_tags_per_job ? {} : nil
    end

    def entry_matches?(entry, query)
      needle = query.downcase
      [ entry.klass, entry.jid, entry.item["error_class"], entry.item["error_message"], entry.args.to_s ]
        .any? { |hay| hay.to_s.downcase.include?(needle) }
    end
  end
end
