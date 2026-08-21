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

    PRESETS = {
      # Because someone will ask. Deliberately loud.
      cyberpunk: {
        dark: {
          bg: "#0A0511", panel: "#140A24", panel_2: "#1C0F31", panel_3: "#26154180",
          line: "#3A1F63", line_soft: "#24123D", text: "#F2E9FF", muted: "#B69BE0", faint: "#7C63A8",
          accent: "#FF2BD1", accent_2: "#00E5FF", good: "#3DF5A5", warn: "#FFC93C", crit: "#FF3B6B"
        }
      }
    }.freeze

    module_function

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
