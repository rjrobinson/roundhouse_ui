module RoundhouseUi
  # Shared search + pagination over a Sidekiq job set (dead, retry, scheduled).
  # Keeps the controllers from duplicating the scan/filter/window logic.
  module JobSetBrowsing
    extend ActiveSupport::Concern

    PER_PAGE = 25
    # The longest needle worth honouring. A megabyte of `q` against twenty thousand
    # entries took five seconds in one request — the substring scan is linear in
    # both, so the needle is a free multiplier on someone else's CPU. Longer than
    # any error message anyone searches for, and checked before any comparison
    # runs (the same ordering as MAX_JOB_CLASS_NAME in lib/roundhouse_ui.rb).
    # The parser owns the bound now — one definition, checked before any character
    # of the input is inspected. Kept as a name because tests and the read-only
    # guard refer to it.
    MAX_QUERY_LENGTH = FilterQuery::MAX_LENGTH
    BULK_CAP = 1_000 # safety ceiling on a single match-set action
    # `unfiltered` means "this action was not authorised". `reason` says why, in the
    # words the operator should read — it was duplicated verbatim in two controllers.
    Matched = Struct.new(:entries, :capped, :unfiltered, :reason, keyword_init: true)

    NO_FILTER = "Refused: a bulk action needs a filter. Without one it would act on " \
                "every job in the set, which is not what this control is for.".freeze

    # Every filter, once per request, rather than re-derived in each action. The
    # queue filter was already assigned in seven places across three controllers;
    # class and error would have made that twenty-one, and a browse that read one
    # filter while its bulk counterpart read another is the failure this whole
    # file is arranged to prevent.
    # Every filter this concern understands. One list, so "all of them" is a thing
    # the code can say.
    #
    # Read from all five, written back as one. `?q=` is now the whole filter —
    # `q=class=EmbeddingWorker error=KeyError stripe` — so a link, a form and a
    # bookmark carry a single value that either travels or doesn't. It used to be
    # five, and "the confirm form carried four of the five" is precisely how a dry
    # run listing two jobs deleted five. The other four survive as a read-only
    # legacy shape (FilterQuery.from_params), because somebody has them bookmarked.
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
      { q: filter.to_s.presence }.compact
    end

    # One parse per request, and everything else reads off it. The ivars below are
    # kept because entry_selected? and TagsHelper are written against them; they are
    # now views onto @filter rather than five independent reads of params, so
    # "the browse read one filter while its bulk counterpart read another" is no
    # longer a shape this code can take.
    def load_filters
      @filter = FilterQuery.from_params(params)
      @query = @filter.text
      @tag = @filter.tag_pair
    end

    # The parsed filter, never nil. entry_selected? is reachable without going
    # through load_filters — the real-Redis tests drive bulk_apply directly, and so
    # could a future action — and a NoMethodError inside the scan predicate is a 500
    # on a page that was only browsing. FilterQuery.none matches everything, which is
    # the same thing "no filter" has always meant here; bulk stays gated because
    # bulk_filter_present? finds nothing to narrow on.
    def filter = @filter ||= FilterQuery.none

    # A refused query selects nothing, rather than being truncated to something
    # shorter that would select MORE. Truncation is the tempting fix and the wrong
    # one: it silently widens, and this predicate drives Delete.
    def query_refused? = filter.invalid?

    # Returns [entries_for_page, has_next?]. Scans only far enough to fill the
    # requested page plus one (to know if a next page exists) — never loads the
    # whole set, so a 50k dead set stays cheap to page through.
    # `tag=key:value` inside ?q= — exact, against a host-defined tag (ADR 0002).
    # Tag values are also in the free-text haystack; safe only because browse and
    # bulk_apply share this one predicate.
    def tag_filter = filter.tag_pair

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
      return false if query_refused?
      # A DEGRADED query dropped a facet it could not use. Browse proceeds on what
      # survived — that is the point of dropping rather than refusing — but what
      # survived selects a SUPERSET of what was typed. `tag=garbage queue=default`
      # becomes `queue=default`, so a Delete here would take the whole queue while
      # the operator believed the tag narrowed it too. Browse and bulk still read
      # one identical filter; bulk just declines to act on a widened one.
      return false if filter.degraded?

      # Reads the SAME parse entry_selected? reads. It used to read @class_filter and
      # friends while the predicate read the FilterQuery, and the two diverged the
      # moment wildcards moved the predicate over: a class-filtered bulk delete found
      # a filter here, found none in the predicate, and took every row in the set.
      # Caught by test_the_class_filter_alone_still_spares_a_longer_name. Those ivars
      # are gone now, so the two cannot be given different answers.
      query.present? || !tag.nil? || filter.any_facets?
    end

    # Why a bulk action was not authorised, in the words to show the operator.
    def bulk_refusal_reason
      return "Refused: that search was not understood, so it selects nothing. #{filter.message}" if query_refused?
      return "Refused: #{filter.notes.join(' ')} Fix the search and the bulk actions come back — " \
             "acting now would touch every job the dropped filter would have excluded." if filter.degraded?

      NO_FILTER
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
      unless bulk_filter_present?(query, tag)
        return Matched.new(entries: [], capped: false, unfiltered: true, reason: bulk_refusal_reason)
      end

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
      return false if query_refused?
      # Compared through the filter, not with ==, so `class=Roundhouse%` narrows here
      # exactly as it does on the dry run and the bulk action — all three read this
      # one predicate. Without a `%` it is still a plain equality: `queue=default`
      # must never also select `default_low`.
      return false unless filter.matches_facet?(:queue, entry.queue)
      return false unless filter.matches_facet?(:klass, RoundhouseUi.unwrapped_class(entry.klass, entry.item))
      return false unless filter.matches_facet?(:error, entry.item["error_class"])

      tags = entry_tags(entry, cache)
      return false if query.present? && !entry_matches?(entry, query, tags)
      return true if tag.nil?

      entry_tagged?(tags, tag)
    end

    # `?queue=name` — exact match, so clicking a queue pill or picking one from
    # the palette narrows to that queue. Exact rather than substring because
    # this feeds bulk_apply too, and "default" must never also select
    # "default_low".
    def queue_filter = filter.queue

    # `class=` and `error=` — the pair behind "find more like this", and typeable.
    # Exact unless you add a %: these render the "delete all matching" buttons
    # beneath them, and a bare substring would select jobs whose ARGUMENTS merely
    # mention the class.
    #
    # Class is compared unwrapped, so the filter means the same string the row
    # displays and the same one the Errors page groups by — one definition of
    # "the same problem" across the console.
    def class_filter = filter.klass

    def error_filter = filter.error

    def entry_tagged?(tags, (key, value))
      # A declared vocabulary is authoritative: filtering on a key the host
      # never declared matches nothing rather than everything.
      declared = Tags.filters
      return false if declared && !declared.key?(key)

      # `tag=squad:plat%` wildcards the VALUE only. The key stays exact, because it
      # is checked against the declared vocabulary above and a wildcarded key would
      # walk straight past that check.
      pattern = FilterQuery::Pattern.for(value)
      return pattern.match?(tags[key.to_s]) if pattern

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
      cheap = [ entry.klass, RoundhouseUi.unwrapped_class(entry.klass, item), entry.jid,
                item["error_class"], item["error_message"], *tags.values ]
      return true if cheap.any? { |hay| hay.to_s.downcase.include?(needle) }

      # Arguments are searched REDACTED — exactly as they are displayed.
      #
      # Searching the raw values turned this box into an oracle. The UI masks
      # api_token, but `q=sk_live_S` matched and `q=sk_live_X` did not, so a secret
      # could be read out one character at a time by someone who can see the console
      # and not the secrets — which is the whole population redact_args exists for.
      # A sixteen-character token falls in a couple of hundred queries, and the same
      # needle scopes a bulk delete, so the oracle worked through the dry run too.
      #
      # Also computed last, and only if the cheap fields missed. It used to be built
      # eagerly into the array above, so every entry paid for stringifying its
      # arguments whether or not anything else had already matched.
      Redaction.apply(entry.args).to_s.downcase.include?(needle)
    end
  end
end
