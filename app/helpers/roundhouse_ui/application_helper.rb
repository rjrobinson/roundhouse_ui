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
    # Both delegate to RoundhouseUi so views and lib/ cannot drift apart again.
    def duration(seconds) = RoundhouseUi.duration(seconds)
    def duration_ms(ms) = RoundhouseUi.duration_ms(ms)

    # Retry attempt as a ladder rather than a number. "retry 21" and "retry 3"
    # are the same shape of text; twenty-one filled rungs going red is not. The
    # count stays beside it, because a ladder answers "how bad" and not "how many".
    def attempt_ladder(count, max = 25)
      filled = count.to_i.clamp(0, max)
      rungs = Array.new(max) do |i|
        state = if i >= filled then nil
        elsif filled > (max * 0.6) then "is-hot"
        else "is-on"
        end
        content_tag(:i, "", class: state)
      end
      safe_join([
        content_tag(:span, safe_join(rungs), class: "rh-ladder",
                    title: "attempt #{filled} of #{max}", aria: { hidden: true }),
        content_tag(:span, "#{filled}/#{max}", class: "rh-sub rh-ladder-n")
      ])
    end

    # How far through the wait a scheduled or retrying job is, as a ring. A job
    # about to fire should not look like one parked for six hours.
    #
    # `since` is when the wait started; without it the ring cannot know the
    # fraction and renders empty rather than guessing.
    def countdown(at, since: nil, label: nil)
      return content_tag(:span, "—", class: "rh-sub") if at.nil?

      remaining = at.to_f - Time.now.to_f
      turn = if since && (total = at.to_f - since.to_f) > 0
        (1.0 - (remaining / total)).clamp(0.0, 1.0)
      else
        remaining <= 0 ? 1.0 : 0.0
      end
      safe_join([
        content_tag(:span, "", class: "rh-ring", style: "--rh-turn:#{turn.round(3)}turn",
                    aria: { hidden: true }),
        content_tag(:span, label || job_time(at, overdue: "now"), class: "rh-sub")
      ])
    end

    # An icon by name. Inline SVG by default; a class name when the host has its
    # own icon font. Only our own SVG constants are marked html_safe — a
    # host-supplied class name goes through content_tag and is escaped.
    def icon(name, extra_class: nil)
      markup = RoundhouseUi::Icons.markup(name)
      return "".html_safe unless markup

      if markup.start_with?("<svg")
        content_tag(:span, markup.html_safe, class: [ "rh-ico", extra_class ].compact.join(" "))
      else
        content_tag(:i, "", class: [ markup, "rh-ico", extra_class ].compact.join(" "), aria: { hidden: true })
      end
    end

    # The runbook for a job, as a link, or nil when the host declared none (#39).
    # Cached per class per request like tags — the same page can ask for the same
    # class dozens of times.
    def runbook_link(klass, item = nil, label: "Runbook")
      url = RoundhouseUi::Runbooks.for(klass, item, cache: (@rh_runbook_cache ||= {}))
      return nil unless url

      link_to label, url, class: "rh-runbook", target: "_blank", rel: "noopener noreferrer",
        title: "Open the runbook for #{RoundhouseUi.unwrapped_class(klass, item)}"
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
