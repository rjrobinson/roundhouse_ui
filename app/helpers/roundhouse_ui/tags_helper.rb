module RoundhouseUi
  # Renders host-defined job tags (see ADR 0002). Resolution is memoized for the
  # life of the request: a page can render hundreds of rows, and ErrorGroups
  # scans up to DEFAULT_SCAN_LIMIT entries, so the host's resolver must not be
  # called once per row when it only varies by class.
  module TagsHelper
    # The per-request memo handed to Tags.for. Nil in per-job mode, where tags
    # vary by payload and caching by class would be wrong.
    def tag_cache
      return nil if RoundhouseUi.job_tags_per_job

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

    # Human description of the active filter set, so a bulk confirm names every
    # constraint that will be applied — not just the text query.
    def filter_description(query, tag)
      parts = []
      parts << "matching “#{query}”" if query.present?
      parts << "tagged #{tag[0]}: #{tag[1]}" if tag
      parts.join(" and ")
    end

    # Any filter active? Bulk-on-match is filter-gated, so this decides whether
    # the bulk bar renders at all.
    def any_filter?(query, tag)
      query.present? || !tag.nil?
    end

    def tag_badge(key, value)
      content_tag(:span, "#{key}: #{value}", class: "rh-pill rh-pill-tag", title: "#{key}: #{value}")
    end
  end
end
