module RoundhouseUi
  # Shared search + pagination over a Sidekiq job set (dead, retry, scheduled).
  # Keeps the controllers from duplicating the scan/filter/window logic.
  module JobSetBrowsing
    extend ActiveSupport::Concern

    PER_PAGE = 25
    BULK_CAP = 1_000 # safety ceiling on a single match-set action
    Matched = Struct.new(:entries, :capped, :unfiltered, keyword_init: true)

    # Every filter, once per request, rather than re-derived in each action. The
    # queue filter was already assigned in seven places across three controllers;
    # class and error would have made that twenty-one, and a browse that read one
    # filter while its bulk counterpart read another is the failure this whole
    # file is arranged to prevent.
    # Every filter this concern understands. One list, so "all of them" is a thing
    # the code can say.
    FILTER_KEYS = %i[q tag queue class error].freeze

    included do
      before_action :load_filters
      helper_method :active_filters
    end

    # The filters currently in force, as URL params. THE single serialization
    # point: every URL and form that must preserve the filter starts from all of it
    # and names only what it changes, so dropping one is not expressible.
    #
    # This was hand-enumerated at six sites. Adding the class/error pair updated
    # three of them, and the confirm form was one of the three that were missed —
    # so a dry run listing two jobs POSTed a request that deleted five, and
    # reported "Deleted 5 matching job(s)" as if that had been approved. The
    # comment above bulk_matches promises the dry run and the action "cannot
    # disagree about what matching means". They could, because they were handed
    # different filters.
    def active_filters
      {
        q: params[:q].to_s.strip.presence,
        tag: params[:tag].presence,
        queue: @queue_filter,
        class: @class_filter,
        error: @error_filter
      }.compact
    end

    def load_filters
      @queue_filter = queue_filter
      @class_filter = class_filter
      @error_filter = error_filter
    end

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
    # The same scan the action runs, stopped one step early, so a dry run and the
    # action it confirms cannot disagree about what "matching" means.
    # Is any filter active? The single source of truth for "this bulk action has a
    # scope". tags_helper's any_filter? delegates here rather than recomputing it —
    # the view and the route disagreeing is exactly how the hole below happened.
    def bulk_filter_present?(query, tag)
      query.present? || !tag.nil? || @queue_filter.present? ||
        @class_filter.present? || @error_filter.present?
    end

    def bulk_matches(set, query, cap = BULK_CAP, tag: nil)
      # An unfiltered bulk action selects EVERY entry: entry_selected? finds no
      # filter to fail, `"".present?` is false, and `return true if tag.nil?` does
      # the rest. So POST /dead/bulk_all with nothing but op=delete emptied the set,
      # up to the cap, and reported "Deleted 50 matching job(s)" as if that were
      # the request. Verified against a real Redis before this guard existed.
      #
      # The comment above bulk_all claimed it was "only offered when a filter is
      # active" — and it was only OFFERED that way. The button was hidden by the
      # view while the route stayed open. The guard belongs here, at the one place
      # both the dry run and the action pass through, not in a before_action that
      # the next destructive action can forget to add.
      return Matched.new(entries: [], capped: false, unfiltered: true) unless bulk_filter_present?(query, tag)

      entries = []
      capped = false
      cache = tag_cache_for(tag)
      set.each do |entry|
        next unless entry_selected?(entry, query, tag, cache)

        entries << entry
        if entries.size >= cap
          capped = true
          break
        end
      end
      Matched.new(entries: entries, capped: capped)
    end

    def bulk_apply(set, query, op, cap = BULK_CAP, tag: nil)
      found = bulk_matches(set, query, cap, tag: tag)
      return found if found.unfiltered

      found.entries.each { |entry| op == "delete" ? entry.delete : entry.retry }
      found
    end

    # Both the browse and bulk paths run every candidate through this, so the
    # rows an operator sees are exactly the rows a bulk action will touch —
    # including when a tag value is what matched the free-text search.
    def entry_selected?(entry, query, tag, cache)
      return false if @queue_filter.present? && entry.queue.to_s != @queue_filter
      return false if @class_filter.present? && RoundhouseUi.unwrapped_class(entry.klass, entry.item).to_s != @class_filter
      return false if @error_filter.present? && entry.item["error_class"].to_s != @error_filter

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

    # `?class=` and `?error=` — the pair behind "find more like this". Exact, and
    # structured rather than typed into the search box for the same reason
    # ?tag= and ?queue= are: this filter renders the "delete all matching"
    # buttons directly beneath it, and a substring would let that select jobs
    # whose ARGUMENTS merely mention the class you clicked.
    #
    # Class is compared unwrapped, so the filter means the same string the row
    # displays and the same one the Errors page groups by — one definition of
    # "the same problem" across the console.
    def class_filter
      params[:class].to_s.strip.presence
    end

    def error_filter
      params[:error].to_s.strip.presence
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
