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
    # The jobs a bulk action would touch, without touching them. Split out of
    # bulk_apply so the dry run and the action itself cannot disagree about what
    # "matching" means — the preview is the same scan, stopped one step early.
    def bulk_matches(set, query, cap = BULK_CAP, tag: nil)
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
      [ matches, capped ]
    end

    def bulk_apply(set, query, op, cap = BULK_CAP, tag: nil)
      matches, capped = bulk_matches(set, query, cap, tag: tag)
      matches.each { |entry| op == "delete" ? entry.delete : entry.retry }
      [ matches.size, capped ]
    end

    # Both the browse and bulk paths run every candidate through this, so the
    # rows an operator sees are exactly the rows a bulk action will touch —
    # including when a tag value is what matched the free-text search.
    def entry_selected?(entry, query, tag, cache)
      return false if @queue_filter.present? && entry.queue.to_s != @queue_filter

      tags = entry_tags(entry, cache)
      return false if query.present? && !entry_matches?(entry, query, tags)
      return true if tag.nil?

      entry_tagged?(tags, tag)
    end

    # `?queue=name` — exact match, so clicking a queue pill or picking one from
    # the palette narrows to that queue. Exact rather than substring because
    # this feeds bulk_apply too, and "default" must never also select
    # "default_low".
    def queue_filter
      params[:queue].to_s.strip.presence
    end

    def entry_tagged?(tags, (key, value))
      # A declared vocabulary is authoritative: filtering on a key the host
      # never declared matches nothing rather than everything.
      declared = Tags.filters
      return false if declared && !declared.key?(key)

      Tags.match?(tags, key, value)
    end

    def entry_tags(entry, cache)
      return Tags::EMPTY unless RoundhouseUi.job_tags

      Tags.for(klass: entry.klass, item: entry.item, cache: cache)
    end

    # Shares the request memo with TagsHelper — controller ivars carry into the
    # view, so an entry resolved while scanning is not resolved again when its
    # badge renders. Tags.for picks the key: class name normally, jid in per-job
    # mode.
    def tag_cache_for(_tag)
      @rh_tag_cache ||= {}
    end

    # Tag values are part of the haystack, so typing a squad name finds its jobs
    # without reaching for the structured filter. Safe to widen here only because
    # browse and bulk_apply share this predicate — if they diverged, a search
    # would show one set of rows and "delete all matching" would act on another.
    def entry_matches?(entry, query, tags = Tags::EMPTY)
      needle = query.downcase
      # Queue matches on equality, not substring: typing a queue name should
      # find its jobs, but this predicate also drives bulk_apply, so "default"
      # must never additionally select "default_low".
      return true if entry.queue.to_s.downcase == needle

      # The unwrapped class is added rather than substituted. Since bulk actions
      # run through this same predicate, replacing would silently empty a saved
      # or habitual "JobWrapper" query — safe in direction, but a bulk query
      # that used to select thousands would quietly select none. Appending only
      # ever widens, and the real class name starts working.
      item = entry.item
      [ entry.klass, RoundhouseUi.unwrapped_class(entry.klass, item), entry.jid,
        item["error_class"], item["error_message"], entry.args.to_s, *tags.values ]
        .any? { |hay| hay.to_s.downcase.include?(needle) }
    end
  end
end
