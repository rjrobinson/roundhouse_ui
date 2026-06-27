module RoundhouseUi
  module NavHelper
    # A sidebar nav item with active state and an optional live-updating badge
    # (filled client-side from /stats via the poll in the layout).
    def nav_link(label, path, icon:, badge: nil, badge_class: nil)
      here = request.path == path || (path != root_path && request.path.start_with?(path))
      link_to path, class: "rh-nav#{' is-active' if here}" do
        safe_join([
          content_tag(:span, icon, class: "rh-ico"),
          content_tag(:span, label, class: "rh-lbl"),
          badge ? content_tag(:span, "", class: "rh-badge #{badge_class}", data: { nav: badge }) : "".html_safe
        ])
      end
    end

    # Health label for a queue from its latency (oldest-job age, in seconds).
    def queue_state(latency, paused: false)
      return [ "Paused", "rh-st-paused" ] if paused
      return [ "Stuck", "rh-st-crit" ]   if latency > 600
      return [ "At risk", "rh-st-warn" ] if latency > 60
      [ "Healthy", "rh-st-ok" ]
    end
  end
end
