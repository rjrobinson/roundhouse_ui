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
    def browse(set, query, page, per = PER_PAGE)
      start = (page - 1) * per
      jobs = []
      has_next = false
      matched = 0

      set.each do |entry|
        next if query.present? && !entry_matches?(entry, query)

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
    def bulk_apply(set, query, op, cap = BULK_CAP)
      matches = []
      capped = false
      set.each do |entry|
        next if query.present? && !entry_matches?(entry, query)

        matches << entry
        if matches.size >= cap
          capped = true
          break
        end
      end
      matches.each { |entry| op == "delete" ? entry.delete : entry.retry }
      [ matches.size, capped ]
    end

    def entry_matches?(entry, query)
      needle = query.downcase
      [ entry.klass, entry.jid, entry.item["error_class"], entry.item["error_message"], entry.args.to_s ]
        .any? { |hay| hay.to_s.downcase.include?(needle) }
    end
  end
end
