module RoundhouseUi
  module ApplicationHelper
    # The class name a row should show: the real job class, not the ActiveJob
    # adapter's wrapper. Resolved here rather than in each template so every
    # surface prints the string the Errors page groups on and the APM link
    # searches for.
    def job_display_class(entry)
      RoundhouseUi.unwrapped_class(entry.klass, entry.item)
    end

    # A job row's identity cell. Class on the first line where the eye lands,
    # jid on a second, dimmer line — one long line of class + hex + link is
    # unreadable once the row also carries squad, queue and error.
    def job_identity(klass, jid, path)
      safe_join([
        link_to(klass, path, class: "rh-joblink"),
        content_tag(:div, jid, class: "rh-sub rh-mono rh-jid", title: jid)
      ])
    end

    # Relative time answers "is this soon?", the clock time answers "does that
    # land inside the maintenance window?". Operators need both, so show both
    # rather than making them hover or do the arithmetic.
    def job_time(at, overdue: "now (overdue)")
      return content_tag(:span, "—", class: "rh-sub") if at.nil?

      relative = at > Time.now ? "in #{distance_of_time_in_words(Time.now, at)}" : overdue
      safe_join([
        content_tag(:span, relative),
        content_tag(:span, at.strftime("%b %-d, %H:%M"), class: "rh-sub rh-mono")
      ], " · ")
    end

    # Set heading that tells the truth under a filter. It used to always print
    # the whole-set size, so "Dead set · 19 jobs" sat above four filtered rows.
    def set_heading(label, showing:, total:, query: nil, tag: nil)
      filtered = any_filter?(query, tag)
      count = filtered ? "#{number_with_delimiter showing} of #{number_with_delimiter total}" : number_with_delimiter(total)
      content_tag(:h2, class: "rh-h2") do
        safe_join([
          "#{label} · #{count} jobs",
          (filtered ? content_tag(:span, filter_description(query, tag), class: "hint") : nil)
        ].compact, " ")
      end
    end

    # Queues carry meaning at a glance (critical vs low), so render them as a
    # pill rather than grey text lost between two columns. On the job sets the
    # pill filters to that queue; `link:` is off where there's nothing to filter
    # (the Queues index itself, grouped Errors rows).
    def queue_pill(name, link: false)
      return content_tag(:span, name, class: "rh-pill rh-mono") unless link

      active = @queue_filter == name.to_s
      link_to name, url_for(only_path: true, page: nil, q: @query.presence,
                            tag: params[:tag].presence,
                            queue: (active ? nil : name)),
        class: "rh-pill rh-mono rh-pill-link#{' is-on' if active}",
        title: active ? "Clear queue filter" : "Show only #{name}"
    end
  end
end
