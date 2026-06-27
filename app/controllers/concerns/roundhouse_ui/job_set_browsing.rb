module RoundhouseUi
  # Shared search + pagination over a Sidekiq job set (dead, retry, scheduled).
  # Keeps the controllers from duplicating the scan/filter/window logic.
  module JobSetBrowsing
    extend ActiveSupport::Concern

    PER_PAGE = 25

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

    def entry_matches?(entry, query)
      needle = query.downcase
      [ entry.klass, entry.jid, entry.item["error_class"], entry.item["error_message"], entry.args.to_s ]
        .any? { |hay| hay.to_s.downcase.include?(needle) }
    end
  end
end
