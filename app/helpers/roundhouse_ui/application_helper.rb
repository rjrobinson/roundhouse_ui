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


    # A one-line, redacted preview of a job's arguments. Sidekiq Web shows args
    # in its queue listing and we did not, which made a queue of one class
    # indistinguishable row to row — the whole question being "which of these is
    # the one I care about".
    #
    # Truncated on purpose: the job page is where the full payload belongs, and a
    # queue listing left open on a second monitor is the wrong place for a long
    # arguments dump. Redaction still applies, but it is key-based, so a bare
    # positional secret is not masked — same caveat as everywhere else args show.
    def job_args_preview(entry, length: 70)
      args = entry.args
      return content_tag(:span, "—", class: "rh-sub") if args.blank?

      full = RoundhouseUi::Redaction.apply(args).map { |a| a.is_a?(String) ? a : a.inspect }.join(", ")
      content_tag(:span, truncate(full, length: length), class: "rh-sub rh-mono", title: full)
    end

    # Compact duration. Raw seconds stop being readable somewhere around a minute
    # and are actively useless by four figures — "10058.0s" is nearly three hours
    # and nobody reads it as that. Two units is all anyone acts on. See #31.
    def duration(seconds)
      secs = seconds.to_f
      return "—" if seconds.nil?
      return "#{secs.round(1)}s" if secs < 60      # 0.4s vs 12s is a real distinction here

      mins = (secs / 60).floor
      return "#{mins}m #{(secs % 60).round}s" if mins < 60

      hours = (secs / 3_600).floor
      return "#{hours}h #{((secs % 3_600) / 60).round}m" if hours < 24

      "#{(secs / 86_400).floor}d #{((secs % 86_400) / 3_600).round}h"
    end

    # Same rule for the millisecond-denominated Metrics table.
    def duration_ms(ms)
      return "—" if ms.nil?
      return "#{ms.round}ms" if ms.to_f < 1_000

      duration(ms.to_f / 1_000)
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
