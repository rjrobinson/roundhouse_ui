module RoundhouseUi
  # Groups failing jobs across the retry + dead sets by a fingerprint of
  # (job class + error class) — so one bad deploy reads as a single issue with
  # a count, not five thousand identical rows. The aggregation Sidekiq Web lacks.
  class ErrorsController < ApplicationController
    # The facets a GROUP can be narrowed by. No queue=: a klass|error group spans
    # every queue its jobs were enqueued on, so there is nothing here for it to
    # apply to — and a pill that filters nothing is the phantom filter the bar
    # exists to prevent. The parser refuses it and says which page it works on.
    FILTER_KEYS = %w[class error tag text].freeze

    def index
      @filter = FilterQuery.from_params(params, keys: FILTER_KEYS)
      @query = @filter.text
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

      # class= and error= match EXACTLY, the same as on the job sets, so a funnel
      # clicked there and a facet typed here mean one thing. Filtered in memory:
      # grouping has already read the entries, so this costs no extra Redis work.
      #
      # A refused query selects nothing rather than everything — the same direction
      # the job sets fail in. Errors has no destructive action, but "nothing matched"
      # must not read as "no such failures exist", which is why the banner renders.
      @groups = [] if @filter.invalid?
      @groups = @groups.select { |g| @filter.matches_facet?(:klass, g[:klass]) }
      @groups = @groups.select { |g| @filter.matches_facet?(:error, g[:error]) }
    end

    private

    # `?tag=key:value`, read off the one parse like everywhere else rather than
    # re-split from params — two readings of one filter is how a page comes to show
    # one scope and act on another.
    def tag_filter
      key, value = @filter.tag_pair
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
