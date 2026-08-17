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

      # Tags resolve per group rather than per entry: every row in a
      # klass|error group shares a class, so a class-derived tag is constant
      # for the group. Counted before filtering, so the quick-filter strip
      # keeps showing every squad's total while one of them is selected.
      @group_tags = @groups.to_h { |g| [ g[:klass], Tags.for(klass: g[:klass], item: {}, cache: tag_cache) ] }
      @tag_counts = tag_counts(@groups)
      @tag = tag_filter
      @groups = @groups.select { |g| Tags.match?(@group_tags[g[:klass]], *@tag) } if @tag
    end

    private

    # `?tag=key:value`, shared shape with the job sets.
    def tag_filter
      key, value = params[:tag].to_s.split(":", 2)
      return nil if key.blank? || value.blank?

      declared = Tags.filters
      return nil if declared && !declared.key?(key)

      [ key, value ]
    end

    # { "squad" => { "core" => 4, "training" => 5 } } — the counts behind the
    # quick-filter strip, from groups already scanned, so this costs no extra
    # Redis work.
    def tag_counts(groups)
      counts = Hash.new { |h, k| h[k] = Hash.new(0) }
      groups.each do |g|
        @group_tags[g[:klass]].each { |key, value| counts[key][value] += g[:count] }
      end
      counts
    end

    def tag_cache
      @rh_tag_cache ||= {}
    end
  end
end
