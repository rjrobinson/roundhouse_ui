module RoundhouseUi
  # Host-configurable colours, as pure CSS custom properties.
  #
  #   RoundhouseUi.theme = { accent: "#FF00FF", accent_2: "#00E5FF" }
  #
  # or per mode, since a colour that reads well on near-black rarely reads well
  # on near-white:
  #
  #   RoundhouseUi.theme = {
  #     dark:  { bg: "#0B0E14", accent: "#FF2BD1" },
  #     light: { bg: "#FFF7FB", accent: "#B3009E" }
  #   }
  #
  # Keys are the token names without the leading dashes; underscores become
  # dashes, so `accent_2` sets `--accent-2`. Anything the layout already defines
  # can be overridden and nothing else — an unknown key is ignored rather than
  # emitted, because a typo silently adding a property is worse than a typo that
  # visibly does nothing.
  #
  # A preset ships as PRESETS[:cyberpunk]; merge or replace as you like.
  module Theme
    # The tokens the layout actually consumes. An allowlist rather than a
    # denylist: this is interpolated into a <style> block, so the set of things
    # a host can name has to be closed.
    TOKENS = %i[
      bg panel panel_2 panel_3 line line_soft text muted faint
      accent accent_2 good warn crit mono sans
    ].freeze

    # Values land inside `--token: VALUE;`. Anything that could close the
    # declaration, open a new rule, or start a comment would let a config value
    # inject arbitrary CSS, so the shape is constrained rather than escaped —
    # there is no HTML-escaping that makes a stylesheet safe.
    SAFE_VALUE = /\A[#\w\s,.()%\-"'\/]+\z/
    UNSAFE = /[;{}<>@\\]|\/\*|\*\//

    MODES = %i[dark light].freeze

    # A palette name lands in a CSS attribute selector, so it is constrained for
    # the same reason the values are — a quote would close the selector and
    # everything after it is arbitrary CSS.
    SAFE_PALETTE_NAME = /\A[a-z0-9_-]{1,40}\z/i

    # Eleven palettes: `cyberpunk`, plus ten themes that each ship their own
    # light AND dark variant, so picking one is not a choice to also give up
    # light mode. Every value below is traced to its project's own palette file
    # rather than typed by hand:
    #
    #   Catppuccin   catppuccin/palette@v1.8.0 palette.json (one light flavour,
    #                Latte, so the three dark flavours share it — upstream's own
    #                design, which is why the names say which flavour you get)
    #   Rosé Pine    rose-pine/palette palette.json (main, moon, dawn)
    #   Nord         nordtheme/nord src/nord.css (nord0–15)
    #   Gruvbox      morhetz/gruvbox colors/gruvbox.vim
    #   Everforest   sainnhe/everforest palette.md (medium variant)
    #   Kanagawa     rebelot/kanagawa.nvim colors.lua (wave, lotus)
    #   Solarized    altercation/solarized README
    #
    # Roles, since every project names its swatches differently: `panel` has to
    # read as distinct from `bg`, `panel_2` has to be dark/light enough for
    # `muted` text to sit on it, and `line_soft` has to be distinct from `panel`
    # or card borders vanish. Solarized ships exactly two surfaces per mode, so
    # its pills recess to the page colour instead of rising above the card —
    # anything lighter is a mid grey that `muted` text cannot sit on.
    PRESETS = {
      # Because someone will ask. Deliberately loud, and dark-only — Settings
      # labels it so, since a dark-only palette is inert in light mode.
      cyberpunk: {
        dark: {
          bg: "#0A0511", panel: "#140A24", panel_2: "#1C0F31", panel_3: "#26154180",
          line: "#3A1F63", line_soft: "#24123D", text: "#F2E9FF", muted: "#B69BE0", faint: "#7C63A8",
          accent: "#FF2BD1", accent_2: "#00E5FF", good: "#3DF5A5", warn: "#FFC93C", crit: "#FF3B6B"
        }
      },
      # Catppuccin Mocha / Latte
      catppuccin: {
        dark: {
          bg: "#181825", panel: "#1E1E2E", panel_2: "#313244", panel_3: "#45475A", line: "#45475A",
          line_soft: "#313244", text: "#CDD6F4", muted: "#A6ADC8", faint: "#7F849C", accent: "#CBA6F7",
          accent_2: "#B4BEFE", good: "#A6E3A1", warn: "#F9E2AF", crit: "#F38BA8"
        },
        light: {
          bg: "#E6E9EF", panel: "#EFF1F5", panel_2: "#DCE0E8", panel_3: "#BCC0CC", line: "#CCD0DA",
          line_soft: "#DCE0E8", text: "#4C4F69", muted: "#6C6F85", faint: "#8C8FA1", accent: "#8839EF",
          accent_2: "#7287FD", good: "#40A02B", warn: "#DF8E1D", crit: "#D20F39"
        }
      },
      # Catppuccin Macchiato / Latte
      catppuccin_macchiato: {
        dark: {
          bg: "#1E2030", panel: "#24273A", panel_2: "#363A4F", panel_3: "#494D64", line: "#494D64",
          line_soft: "#363A4F", text: "#CAD3F5", muted: "#A5ADCB", faint: "#8087A2", accent: "#C6A0F6",
          accent_2: "#B7BDF8", good: "#A6DA95", warn: "#EED49F", crit: "#ED8796"
        },
        light: {
          bg: "#E6E9EF", panel: "#EFF1F5", panel_2: "#DCE0E8", panel_3: "#BCC0CC", line: "#CCD0DA",
          line_soft: "#DCE0E8", text: "#4C4F69", muted: "#6C6F85", faint: "#8C8FA1", accent: "#8839EF",
          accent_2: "#7287FD", good: "#40A02B", warn: "#DF8E1D", crit: "#D20F39"
        }
      },
      # Catppuccin Frappe / Latte
      catppuccin_frappe: {
        dark: {
          bg: "#292C3C", panel: "#303446", panel_2: "#414559", panel_3: "#51576D", line: "#51576D",
          line_soft: "#414559", text: "#C6D0F5", muted: "#A5ADCE", faint: "#838BA7", accent: "#CA9EE6",
          accent_2: "#BABBF1", good: "#A6D189", warn: "#E5C890", crit: "#E78284"
        },
        light: {
          bg: "#E6E9EF", panel: "#EFF1F5", panel_2: "#DCE0E8", panel_3: "#BCC0CC", line: "#CCD0DA",
          line_soft: "#DCE0E8", text: "#4C4F69", muted: "#6C6F85", faint: "#8C8FA1", accent: "#8839EF",
          accent_2: "#7287FD", good: "#40A02B", warn: "#DF8E1D", crit: "#D20F39"
        }
      },
      # Rose Pine Main / Dawn
      rose_pine: {
        dark: {
          bg: "#191724", panel: "#1F1D2E", panel_2: "#26233A", panel_3: "#26233A", line: "#26233A",
          line_soft: "#26233A", text: "#E0DEF4", muted: "#908CAA", faint: "#6E6A86", accent: "#C4A7E7",
          accent_2: "#9CCFD8", good: "#31748F", warn: "#F6C177", crit: "#EB6F92"
        },
        light: {
          bg: "#FAF4ED", panel: "#FFFAF3", panel_2: "#F2E9E1", panel_3: "#F2E9E1", line: "#F2E9E1",
          line_soft: "#F2E9E1", text: "#464261", muted: "#797593", faint: "#9893A5", accent: "#907AA9",
          accent_2: "#56949F", good: "#286983", warn: "#EA9D34", crit: "#B4637A"
        }
      },
      # Rose Pine Moon / Dawn
      rose_pine_moon: {
        dark: {
          bg: "#232136", panel: "#2A273F", panel_2: "#393552", panel_3: "#393552", line: "#393552",
          line_soft: "#393552", text: "#E0DEF4", muted: "#908CAA", faint: "#6E6A86", accent: "#C4A7E7",
          accent_2: "#9CCFD8", good: "#3E8FB0", warn: "#F6C177", crit: "#EB6F92"
        },
        light: {
          bg: "#FAF4ED", panel: "#FFFAF3", panel_2: "#F2E9E1", panel_3: "#F2E9E1", line: "#F2E9E1",
          line_soft: "#F2E9E1", text: "#464261", muted: "#797593", faint: "#9893A5", accent: "#907AA9",
          accent_2: "#56949F", good: "#286983", warn: "#EA9D34", crit: "#B4637A"
        }
      },
      # Nord Polar Night / Snow Storm
      nord: {
        dark: {
          bg: "#2E3440", panel: "#3B4252", panel_2: "#434C5E", panel_3: "#4C566A", line: "#4C566A",
          line_soft: "#434C5E", text: "#ECEFF4", muted: "#E5E9F0", faint: "#D8DEE9", accent: "#88C0D0",
          accent_2: "#81A1C1", good: "#A3BE8C", warn: "#EBCB8B", crit: "#BF616A"
        },
        light: {
          bg: "#E5E9F0", panel: "#ECEFF4", panel_2: "#D8DEE9", panel_3: "#D8DEE9", line: "#D8DEE9",
          line_soft: "#E5E9F0", text: "#2E3440", muted: "#434C5E", faint: "#4C566A", accent: "#5E81AC",
          accent_2: "#81A1C1", good: "#A3BE8C", warn: "#EBCB8B", crit: "#BF616A"
        }
      },
      # Gruvbox Dark / Light
      gruvbox: {
        dark: {
          bg: "#282828", panel: "#32302F", panel_2: "#3C3836", panel_3: "#504945", line: "#504945",
          line_soft: "#3C3836", text: "#EBDBB2", muted: "#BDAE93", faint: "#928374", accent: "#D3869B",
          accent_2: "#83A598", good: "#B8BB26", warn: "#FABD2F", crit: "#FB4934"
        },
        light: {
          bg: "#F2E5BC", panel: "#FBF1C7", panel_2: "#EBDBB2", panel_3: "#D5C4A1", line: "#D5C4A1",
          line_soft: "#EBDBB2", text: "#3C3836", muted: "#665C54", faint: "#7C6F64", accent: "#8F3F71",
          accent_2: "#076678", good: "#79740E", warn: "#B57614", crit: "#9D0006"
        }
      },
      # Everforest Dark / Light medium
      everforest: {
        dark: {
          bg: "#232A2E", panel: "#2D353B", panel_2: "#343F44", panel_3: "#3D484D", line: "#475258",
          line_soft: "#3D484D", text: "#D3C6AA", muted: "#9DA9A0", faint: "#859289", accent: "#7FBBB3",
          accent_2: "#83C092", good: "#A7C080", warn: "#DBBC7F", crit: "#E67E80"
        },
        light: {
          bg: "#EFEBD4", panel: "#FDF6E3", panel_2: "#F4F0D9", panel_3: "#EFEBD4", line: "#E6E2CC",
          line_soft: "#EFEBD4", text: "#5C6A72", muted: "#829181", faint: "#939F91", accent: "#3A94C5",
          accent_2: "#35A77C", good: "#8DA101", warn: "#DFA000", crit: "#F85552"
        }
      },
      # Kanagawa Wave / Lotus
      kanagawa: {
        dark: {
          bg: "#1F1F28", panel: "#2A2A37", panel_2: "#363646", panel_3: "#223249", line: "#54546D",
          line_soft: "#363646", text: "#DCD7BA", muted: "#C8C093", faint: "#727169", accent: "#7E9CD8",
          accent_2: "#957FB8", good: "#98BB6C", warn: "#E6C384", crit: "#E46876"
        },
        light: {
          bg: "#E5DDB0", panel: "#F2ECBC", panel_2: "#DCD5AC", panel_3: "#D5CEA3", line: "#D5CEA3",
          line_soft: "#DCD5AC", text: "#545464", muted: "#716E61", faint: "#8A8980", accent: "#4D699B",
          accent_2: "#624C83", good: "#6F894E", warn: "#CC6D00", crit: "#B35B79"
        }
      },
      # Solarized Dark / Light
      solarized: {
        dark: {
          bg: "#002B36", panel: "#073642", panel_2: "#002B36", panel_3: "#073642", line: "#586E75",
          line_soft: "#002B36", text: "#93A1A1", muted: "#839496", faint: "#586E75", accent: "#268BD2",
          accent_2: "#6C71C4", good: "#859900", warn: "#B58900", crit: "#DC322F"
        },
        light: {
          bg: "#EEE8D5", panel: "#FDF6E3", panel_2: "#EEE8D5", panel_3: "#EEE8D5", line: "#93A1A1",
          line_soft: "#EEE8D5", text: "#586E75", muted: "#657B83", faint: "#93A1A1", accent: "#268BD2",
          accent_2: "#6C71C4", good: "#859900", warn: "#B58900", crit: "#DC322F"
        }
      }
    }.freeze

    module_function

    # CSS for every selectable palette: one block per palette per mode.
    def selectable_css(config = RoundhouseUi.themes)
      blocks = selectable(config).filter_map do |name, tokens|
        normalize(tokens).filter_map { |mode, toks|
          decls = declarations(toks)
          next if decls.empty?

          "#{palette_selector(name, mode)} { #{decls} }"
        }.join("\n").presence
      end
      blocks.any? ? blocks.join("\n") : nil
    end

    # The one mode a palette covers, or nil when it covers both. A dark-only
    # palette silently does nothing in light mode — the tokens are there but the
    # selector never matches — so the menu has to say so rather than looking
    # broken.
    def only_mode(config)
      modes = normalize(config).keys
      modes.first if modes.size == 1 && MODES.include?(modes.first)
    end

    def palette_selector(name, mode)
      base = %(:root[data-rh-palette="#{name}"])
      case mode
      when :light then %(#{base}[data-theme="light"])
      when :dark  then %(#{base}:not([data-theme="light"]))
      else             base
      end
    end

    # Named palettes a viewer may pick from on the Settings page. Emitted as
    # [data-rh-palette="name"] blocks so a choice is one attribute on :root —
    # the browser stores which name, never the colours. Storing values would mean
    # applying viewer-controlled strings as CSS, which is the thing the
    # server-side allowlist exists to prevent.
    def selectable(config = RoundhouseUi.themes)
      return {} unless RoundhouseUi.allow_theme_selection
      return {} if config.blank?

      config.to_h.symbolize_keys.select { |name, _| name.to_s.match?(SAFE_PALETTE_NAME) }
    end

    # The CSS to append after the layout's own :root blocks, or nil when the host
    # configured nothing. Later declarations win, so this needs no !important and
    # the shipped defaults remain the fallback for any token left unset.
    def css(config = RoundhouseUi.theme)
      return nil if config.blank?

      blocks = normalize(config).filter_map do |mode, tokens|
        decls = declarations(tokens)
        next if decls.empty?

        "#{selector(mode)} { #{decls} }"
      end
      blocks.any? ? blocks.join("\n") : nil
    end

    # A flat hash is treated as applying to both modes; a hash keyed by mode is
    # taken as given.
    def normalize(config)
      config = config.symbolize_keys
      return config.slice(*MODES) if config.keys.any? { |k| MODES.include?(k) }

      { all: config }
    end

    def selector(mode)
      case mode
      when :light then ':root[data-theme="light"]'
      when :dark  then ":root:not([data-theme=\"light\"])"
      else             ":root"
      end
    end

    def declarations(tokens)
      tokens.to_h.symbolize_keys.filter_map { |key, value|
        next unless TOKENS.include?(key)
        next unless safe?(value)

        "--#{key.to_s.tr("_", "-")}: #{value};"
      }.join(" ")
    end

    def safe?(value)
      str = value.to_s
      str.present? && str.length <= 120 && str.match?(SAFE_VALUE) && !str.match?(UNSAFE)
    end
  end
end
