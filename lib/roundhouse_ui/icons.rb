module RoundhouseUi
  # Icons as inline SVG. No font, no request, no CSP change, and identical on
  # every platform — which the Unicode glyphs these replace were not: `⛁` and
  # `☷` have no glyph at all on older Windows, `⚙`/`☾`/`⚠` get substituted for
  # emoji on some platforms, and `▦` and `▤` are indistinguishable at 16px.
  #
  # Hosts that already ship an icon font can use it instead:
  #
  #   RoundhouseUi.icons = :font_awesome
  #   RoundhouseUi.icons = { dashboard: "fa-solid fa-gauge-high", ... }
  #
  # Roundhouse never loads a font itself in either case. It emits class names and
  # the host's existing pipeline supplies the glyphs, which is what keeps the
  # self-contained CSP intact.
  module Icons
    VIEWBOX = "0 0 24 24".freeze
    # Geometric on purpose: an operations console is not the place for
    # personality, and a 1.9 stroke stays legible at 15px.
    ATTRS = %(viewBox="#{VIEWBOX}" width="15" height="15" fill="none" stroke="currentColor" ) +
            %(stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false")

    PATHS = {
      dashboard: '<rect x="3" y="3" width="7.5" height="7.5" rx="1.4"/><rect x="13.5" y="3" width="7.5" height="7.5" rx="1.4"/><rect x="3" y="13.5" width="7.5" height="7.5" rx="1.4"/><rect x="13.5" y="13.5" width="7.5" height="7.5" rx="1.4"/>',
      queues:    '<path d="M4 7h16M4 12h16M4 17h10"/>',
      retries:   '<path d="M20 11a8 8 0 1 0-2.5 6.9"/><path d="M20 5v6h-6"/>',
      dead:      '<circle cx="12" cy="12" r="8.4"/><path d="M9 9l6 6M15 9l-6 6"/>',
      errors:    '<path d="M12 4.2 2.8 20h18.4L12 4.2Z"/><path d="M12 10v4"/><circle cx="12" cy="17" r=".6" fill="currentColor"/>',
      busy:      '<circle cx="12" cy="12" r="8.4"/><path d="M12 3.6a8.4 8.4 0 0 1 0 16.8Z" fill="currentColor" stroke="none"/>',
      metrics:   '<path d="M4 20V13M9.3 20V8M14.7 20v-6M20 20V4"/>',
      snapshots: '<ellipse cx="12" cy="6" rx="8" ry="3"/><path d="M4 6v6c0 1.7 3.6 3 8 3s8-1.3 8-3V6"/><path d="M4 12v6c0 1.7 3.6 3 8 3s8-1.3 8-3v-6"/>',
      audit:     '<path d="M4 6h16M4 11h16M4 16h9"/><path d="M15.5 18.5l1.8 1.8 3.2-3.6"/>',
      settings:  '<path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2.1"/><circle cx="7" cy="17" r="2.1"/>',
      scheduled: '<circle cx="12" cy="12" r="8.4"/><path d="M12 7.6V12l3.2 2"/>',
      workers:   '<rect x="6.5" y="6.5" width="11" height="11" rx="1.6"/><path d="M10 3v3M14 3v3M10 18v3M14 18v3M3 10h3M3 14h3M18 10h3M18 14h3"/>',
      capsules:  '<rect x="3.5" y="3.5" width="7" height="7" rx="1.3"/><rect x="13.5" y="3.5" width="7" height="7" rx="1.3"/><rect x="3.5" y="13.5" width="7" height="7" rx="1.3"/><path d="M17 14v6M14 17h6"/>',
      redis:     '<path d="M3.6 7.5 12 4l8.4 3.5L12 11 3.6 7.5Z"/><path d="M3.6 12 12 15.5 20.4 12"/><path d="M3.6 16.5 12 20l8.4-3.5"/>',
      enqueue:   '<path d="M12 5v14M5 12h14"/>',
      width:     '<path d="M3 12h18"/><path d="M7 8l-4 4 4 4M17 8l4 4-4 4"/>',
      theme:     '<path d="M20 14.5A8.5 8.5 0 1 1 9.5 4a6.8 6.8 0 0 0 10.5 10.5Z"/>',
      pause:     '<path d="M9.5 5v14M14.5 5v14"/>',
      delete:    '<path d="M5 7h14"/><path d="M9 7V4.6h6V7"/><path d="M6.5 7l1 12.4h9L18 7"/>',
      ok:        '<path d="M4.5 12.5l5 5L20 6.5"/>',
      warn:      '<path d="M12 4.2 2.8 20h18.4L12 4.2Z"/><path d="M12 10v4"/><circle cx="12" cy="17" r=".6" fill="currentColor"/>',
      stalled:   '<circle cx="12" cy="12" r="8.4"/><path d="M8.5 12h7"/>',
      search:    '<circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.4 15.4 21 21"/>',
      runbook:   '<path d="M5 4h9l5 5v11H5Z"/><path d="M14 4v5h5"/><path d="M8.5 13h7M8.5 16.5h4.5"/>',
      # Default trace glyph: an external-link arrow. Roundhouse ships no vendor
      # logo — see Observability adapters, which may supply their own mark.
      trace_out: '<path d="M14 4h6v6"/><path d="M20 4 11 13"/><path d="M18 14v4.5A1.5 1.5 0 0 1 16.5 20h-11A1.5 1.5 0 0 1 4 18.5v-11A1.5 1.5 0 0 1 5.5 6H10"/>'
    }.freeze

    # For hosts that already load FontAwesome Free. Names chosen from the free
    # set so nothing here needs a Pro licence.
    FONT_AWESOME = {
      dashboard: "fa-solid fa-gauge-high",     queues:    "fa-solid fa-layer-group",
      retries:   "fa-solid fa-rotate-right",   dead:      "fa-solid fa-circle-xmark",
      errors:    "fa-solid fa-triangle-exclamation", busy: "fa-solid fa-circle-half-stroke",
      metrics:   "fa-solid fa-chart-simple",   snapshots: "fa-solid fa-database",
      audit:     "fa-solid fa-list-check",     settings:  "fa-solid fa-sliders",
      scheduled: "fa-regular fa-clock",        workers:   "fa-solid fa-microchip",
      capsules:  "fa-solid fa-table-cells-large", redis:  "fa-solid fa-cubes-stacked",
      enqueue:   "fa-solid fa-plus",           width:     "fa-solid fa-arrows-left-right",
      theme:     "fa-solid fa-moon",           pause:     "fa-solid fa-pause",
      delete:    "fa-solid fa-trash-can",      ok:        "fa-solid fa-check",
      warn:      "fa-solid fa-triangle-exclamation", stalled: "fa-solid fa-minus",
      search:    "fa-solid fa-magnifying-glass", runbook: "fa-regular fa-file-lines",
      trace_out: "fa-solid fa-arrow-up-right-from-square"
    }.freeze

    module_function

    # An icon's markup, or nil when the name is unknown — an unknown name draws
    # nothing rather than raising, so a typo in a host's mapping cannot take a
    # page down.
    def markup(name, config = RoundhouseUi.icons)
      key = name.to_s.to_sym
      case config
      when :font_awesome then class_name(FONT_AWESOME[key])
      when Hash          then class_name(config[key] || config[name.to_s])
      else                    svg(key)
      end
    end

    def svg(key)
      path = PATHS[key]
      return nil unless path

      %(<svg #{ATTRS}>#{path}</svg>)
    end

    # Host-supplied, so it is never marked html_safe — the caller escapes it into
    # a class attribute.
    def class_name(value)
      value.presence
    end
  end
end
