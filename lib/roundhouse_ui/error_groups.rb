require "sidekiq/api"

module RoundhouseUi
  # Groups failing jobs across the retry + dead sets (and the sidekiq-failures
  # `failed` set, when opted in) by a fingerprint of job class + error class —
  # so one bad deploy reads as a single issue with a count, not thousands of
  # identical rows. Used by the Errors page and the dashboard's "top failing"
  # panel, so the aggregation lives here rather than in a controller.
  class ErrorGroups
    DEFAULT_SCAN_LIMIT = 1_000 # cap entries scanned per pass; surfaced honestly

    Result = Struct.new(:groups, :scanned, :truncated, keyword_init: true)

    def initialize(query: nil, limit: DEFAULT_SCAN_LIMIT)
      @query = query.to_s.strip
      @limit = limit
    end

    def call
      groups = {}
      scanned = 0
      truncated = false

      sources.each do |source, set|
        set.each do |entry|
          scanned += 1
          if scanned > @limit
            truncated = true
            break
          end
          record(groups, source, entry)
        end
        break if truncated
      end

      list = groups.values.sort_by { |g| -g[:count] }
      list = list.select { |g| "#{g[:klass]} #{g[:error]}".downcase.include?(@query.downcase) } if @query.present?
      Result.new(groups: list, scanned: scanned, truncated: truncated)
    end

    private

    # Sidekiq's native sets, plus the sidekiq-failures `failed` set when opted in
    # and loaded. Its FailureSet is a Sidekiq::JobSet, so it iterates like the rest.
    def sources
      sets = { "retry" => Sidekiq::RetrySet.new, "dead" => Sidekiq::DeadSet.new }
      if RoundhouseUi.show_sidekiq_failures && defined?(Sidekiq::Failures::FailureSet)
        sets["failed"] = Sidekiq::Failures::FailureSet.new
      end
      sets
    end

    def record(groups, source, entry)
      error = entry.item["error_class"] || "UnknownError"
      group = (groups["#{entry.klass}|#{error}"] ||= {
        klass: entry.klass, error: error, count: 0, last_at: nil, queues: [], sources: []
      })
      group[:count]  += 1
      group[:queues] |= [ entry.queue ]
      group[:sources] |= [ source ]
      at = entry.at
      group[:last_at] = at if at && (group[:last_at].nil? || at > group[:last_at])
    end
  end
end
