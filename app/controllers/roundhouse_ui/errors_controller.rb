module RoundhouseUi
  # Groups failing jobs across the retry + dead sets by a fingerprint of
  # (job class + error class) — so one bad deploy reads as a single issue with
  # a count, not five thousand identical rows. The aggregation Sidekiq Web lacks.
  class ErrorsController < ApplicationController
    SCAN_LIMIT = 1_000 # cap entries scanned per pass; shown honestly in the view

    def index
      @query = params[:q].to_s.strip
      @scan_limit = SCAN_LIMIT
      @groups, @scanned, @truncated = aggregate
    end

    private

    def aggregate
      groups = {}
      scanned = 0
      truncated = false

      { "retry" => Sidekiq::RetrySet.new, "dead" => Sidekiq::DeadSet.new }.each do |source, set|
        set.each do |entry|
          scanned += 1
          if scanned > SCAN_LIMIT
            truncated = true
            break
          end
          record(groups, source, entry)
        end
        break if truncated
      end

      list = groups.values.sort_by { |g| -g[:count] }
      list = list.select { |g| "#{g[:klass]} #{g[:error]}".downcase.include?(@query.downcase) } if @query.present?
      [ list, scanned, truncated ]
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
