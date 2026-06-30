module RoundhouseUi
  # Groups failing jobs across the retry + dead sets by a fingerprint of
  # (job class + error class) — so one bad deploy reads as a single issue with
  # a count, not five thousand identical rows. The aggregation Sidekiq Web lacks.
  class ErrorsController < ApplicationController
    def index
      @query = params[:q].to_s.strip
      @scan_limit = ErrorGroups::DEFAULT_SCAN_LIMIT
      result = ErrorGroups.new(query: @query).call
      @groups, @scanned, @truncated = result.groups, result.scanned, result.truncated
    end
  end
end
