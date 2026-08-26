module RoundhouseUi
  # Renders host-defined job tags (see ADR 0002). Resolution is memoized for the
  # life of the request: a page can render hundreds of rows, and ErrorGroups
  # scans up to DEFAULT_SCAN_LIMIT entries, so the host's resolver must not be
  # called once per row when it only varies by class.
  module TagsHelper
    # The per-request memo handed to Tags.for, shared with JobSetBrowsing so a
    # class (or job) resolved while scanning is not resolved again when its
    # badge renders. Tags.for chooses the key: class name normally, jid in
    # per-job mode.
    def tag_cache
      @rh_tag_cache ||= {}
    end

    # Tags for one job entry, as a { "key" => "value" } Hash.
    def tags_for(entry)
      return Tags::EMPTY unless RoundhouseUi.job_tags

      Tags.for(klass: entry.klass, item: entry.item, cache: tag_cache)
    end

    # Tags for a class name alone — used by grouped Errors, where every entry in
    # a group shares a class, so a class-derived tag is constant for the group.
    # Passes no payload, so a per-job resolver correctly declines rather than
    # attributing one job's tags to the whole group.
    def tags_for_class(klass)
      return Tags::EMPTY unless RoundhouseUi.job_tags

      Tags.for(klass: klass, item: {}, cache: tag_cache)
    end

    # Pills for a resolved tag Hash. Renders nothing when there are no tags, so
    # every call site can be unconditional.
    def tag_badges(tags)
      return if tags.blank?

      safe_join(tags.map { |key, value| tag_badge(key, value) }, " ")
    end

    # Tags get their own table column rather than an inline badge: class names
    # vary wildly in length, so inline badges land at ragged x-positions and
    # can't be scanned down. Only worth a column when a host configured tags.
    def tag_column?
      RoundhouseUi.job_tags.present?
    end

    # Header for that column. With the usual single dimension this is the tag's
    # own name ("squad"); with several there's no one right label.
    def tag_column_label
      keys = Tags.filters&.keys
      keys&.one? ? keys.first.titleize : "Tags"
    end

    # Cell contents. Stacks when a host defines more than one dimension.
    def tag_cell(tags)
      return content_tag(:span, "—", class: "rh-sub") if tags.blank?

      tag_badges(tags)
    end

    # Values offered as filter chips where no counts are available. Prefers the
    # host's declared vocabulary, so the chips stay put as you filter; falls back
    # to whatever the visible rows happen to carry, which at least beats nothing
    # but shifts as you page.
    def tag_vocabulary
      declared = Tags.filters
      return declared if declared.present?

      seen = Hash.new { |h, k| h[k] = [] }
      Array(@jobs).each do |job|
        tags_for(job).each { |key, value| seen[key] << value unless seen[key].include?(value) }
      end
      seen.transform_values(&:sort)
    end

    # Human description of the active filter set, so a bulk confirm names every
    # constraint that will be applied — not just the text query.
    # Every active constraint must appear here. A confirm that names only the
    # text query while a queue or tag also narrows the set understates what is
    # about to be destroyed.
    def filter_description(query, tag, queue = @queue_filter)
      parts = []
      parts << "matching “#{query}”" if query.present?
      parts << "tagged #{tag[0]}: #{tag[1]}" if tag
      parts << "in queue #{queue}" if queue.present?
      parts << like_description if @class_filter.present?
      parts.join(" and ")
    end

    # "find more like this", said back to you. The wording has to be exact about
    # what it selected, because the bulk Delete sitting next to it acts on
    # precisely this set and nothing wider.
    def like_description
      return "like #{@class_filter}" if @error_filter.blank?

      "like #{@class_filter} failing with #{@error_filter}"
    end

    # Any filter active? Bulk-on-match is filter-gated, so this decides whether
    # the bulk bar renders at all — and which empty-state copy is honest.
    def any_filter?(query, tag, queue = @queue_filter)
      query.present? || !tag.nil? || queue.present? || @class_filter.present?
    end

    # Value only — the key is near-constant down a column, so repeating it is
    # noise. It stays in the tooltip for hosts with more than one dimension.
    def tag_badge(key, value)
      content_tag(:span, value, class: "rh-pill rh-pill-tag", title: "#{key}: #{value}")
    end
  end
end
