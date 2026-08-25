require "test_helper"

module RoundhouseUi
  # Three button pairs were hand-matched by eye in a single day, and each fix held
  # only until the next control. The token scale is not what stops that — this is.
  # Every dimension on every control has to come from a --ctl-* token, so a ninth
  # control with typed pixels fails here, by name, before it reaches a page.
  class ControlScaleTest < ActiveSupport::TestCase
    CONTROLS = %w[
      rh-btn rh-runbook rh-pill rh-badge rh-kbd rh-iconbtn rh-ro rh-trace-btn rh-cap-pick
    ].freeze

    # Properties someone can get wrong by a pixel. Colour is not one of them.
    DIMENSIONS = %w[
      height width min-height min-width font-size line-height gap
      padding padding-top padding-bottom padding-left padding-right
      border-radius
    ].freeze

    # A length with a unit typed into a control rule is the whole problem: 28px,
    # 11.5px, 999px. Everything else is fine — 0 has no size to get wrong, a
    # percentage is a fraction of the parent, a unitless line-height is a ratio,
    # and a --ctl-* token is the point of the exercise. Checked per component
    # rather than per value, because `padding: 0 var(--ctl-px-md)` is two things.
    UNIT = /\d\s*(?:px|rem|em|ch|ex|vh|vw|vmin|vmax|pt|pc|in|cm|mm)\b/

    def css
      @css ||= File.read(RoundhouseUi::Engine.root.join("app/views/layouts/roundhouse_ui/application.html.erb"))
    end

    # Just the stylesheet, with comments gone. Both matter, and the second one
    # cost an hour: a comment contains no braces, so a selector pattern of
    # [^{}]+ swallows the whole comment block above a rule. The first version of
    # this test then skipped anything starting with "/*" — which was every real
    # control rule in the file. It reported zero offences against three
    # deliberately broken ones. Hence test_the_scanner_actually_sees_a_control.
    def stylesheet
      @stylesheet ||= begin
        style = css.scan(/<style[^>]*>(.*?)<\/style>/m).flatten.join("\n")
        style.gsub(/\/\*.*?\*\//m, "").gsub(/<%=?.*?%>/m, "")
      end
    end

    # Every rule whose selector names one of the control classes. Selectors
    # cannot contain braces, so nested at-rules fall out and their inner rules
    # are matched on their own.
    def control_rules
      stylesheet.scan(/([^{}]+)\{([^{}]*)\}/m).filter_map do |selector, body|
        sel = selector.strip.gsub(/\s+/, " ")
        next if sel.empty? || sel.start_with?("@")
        next unless CONTROLS.any? { |c| sel.split(/[\s,>+~]+/).any? { |t| t.split(":").first.to_s.split(".").include?(c) } }

        [ sel, body ]
      end
    end

    def offences
      control_rules.flat_map do |selector, body|
        body.scan(/([a-z-]+)\s*:\s*([^;}]+)/).filter_map do |prop, value|
          next unless DIMENSIONS.include?(prop)

          v = value.strip
          # Remove the tokens, then see whether any hand-typed length is left.
          next unless v.gsub(/var\(--ctl-[a-z0-9-]+\)/, " ").match?(UNIT)

          "#{selector} { #{prop}: #{v} }"
        end
      end
    end

    def test_every_control_class_still_exists
      missing = CONTROLS.reject { |c| stylesheet.include?(".#{c}") }
      assert_empty missing, "these control classes are gone; update CONTROLS or the CSS"
    end

    # The offence check can only fail if the scanner is finding rules. Asserting
    # "no offences" against a scanner that matches nothing passes forever, which
    # is exactly what the first version of this file did.
    def test_the_scanner_actually_sees_a_control
      rules = control_rules
      refute_empty rules, "the scanner matched no control rules at all"

      base = rules.find { |sel, body| sel.include?(".rh-runbook") && body.include?("--ctl-h-") }
      assert base, "no rule gives .rh-runbook a height from the scale — the scanner is broken " \
                   "or the control lost its box"

      CONTROLS.each do |c|
        assert rules.any? { |sel, _| sel.split(/[\s,>+~]+/).any? { |t| t.split(":").first.to_s.split(".").include?(c) } },
          ".#{c} is in CONTROLS but the scanner never matched a rule for it"
      end
    end

    def test_no_control_hand_rolls_its_own_dimensions
      assert_empty offences, <<~WHY
        A control is setting a size that did not come from the scale:

          #{offences.join("\n          ")}

        Every dimension on a control belongs to a --ctl-* token. Hand-typed pixels
        are how .rh-trace-btn ended up 2px taller than the .rh-runbook pill it sat
        beside, and how ⌘K ended up 9px shorter than the icon buttons next to it.
        Add a token, or use one of the existing sizes.
      WHY
    end

    # "No bad dimensions" passes trivially if a control has no dimensions at all.
    # Deleting the base rule left every control unstyled and this file silent, so
    # the positive half is asserted too: each one gets a height from the scale.
    def test_every_control_takes_a_height_from_the_scale
      rules = control_rules
      CONTROLS.each do |c|
        sized = rules.any? do |sel, body|
          names = sel.split(/[\s,>+~]+/).flat_map { |t| t.split(":").first.to_s.split(".") }
          names.include?(c) && body.match?(/(?:^|;)\s*height\s*:\s*var\(--ctl-h-/)
        end
        assert sized, ".#{c} never gets a height from the scale — it has no box, or it " \
                      "is getting one from somewhere the scale does not control"
      end
    end

    def test_the_scale_defines_the_sizes_it_promises
      %w[
        --ctl-h-sm --ctl-h-md --ctl-h-lg --ctl-px-sm --ctl-px-md
        --ctl-fs-sm --ctl-fs-md --ctl-r --ctl-r-lg --ctl-r-pill
        --ctl-icon-sm --ctl-icon-md --ctl-gap
      ].each do |token|
        assert_match(/#{Regexp.escape(token)}\s*:/, css, "#{token} is used but never defined")
      end
    end

    def test_the_scale_is_not_host_overridable
      # Colour is the host's to change; structure is not. A dimension in
      # Theme::TOKENS would let a config value resize every control in the UI.
      overlap = Theme::TOKENS.map(&:to_s) & %w[ctl_h_sm ctl_h_md ctl_px_md ctl_fs_md ctl_r ctl_gap]
      assert_empty overlap, "control dimensions must stay internal"
    end
  end
end
