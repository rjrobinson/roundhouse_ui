require "test_helper"

module RoundhouseUi
  class ThemeTest < ActiveSupport::TestCase
    def teardown = RoundhouseUi.theme = nil

    def test_no_theme_emits_nothing
      assert_nil Theme.css(nil)
      assert_nil Theme.css({})
    end

    def test_a_flat_hash_applies_to_both_modes
      css = Theme.css(accent: "#FF2BD1")
      assert_includes css, ":root {"
      assert_includes css, "--accent: #FF2BD1;"
    end

    def test_underscores_become_dashes
      assert_includes Theme.css(accent_2: "#00E5FF"), "--accent-2: #00E5FF;"
    end

    # A colour that reads on near-black rarely reads on near-white, so a host has
    # to be able to say different things for each.
    def test_per_mode_config_targets_the_right_selectors
      css = Theme.css(dark: { bg: "#0A0511" }, light: { bg: "#FFF7FB" })
      assert_includes css, ':root:not([data-theme="light"]) { --bg: #0A0511; }'
      assert_includes css, ':root[data-theme="light"] { --bg: #FFF7FB; }'
    end

    def test_partial_themes_leave_other_tokens_alone
      css = Theme.css(accent: "#FF2BD1")
      assert_includes css, "--accent:"
      refute_includes css, "--bg:"
    end

    # A typo that silently adds a property is worse than one that visibly does
    # nothing, so the token list is closed.
    def test_unknown_tokens_are_ignored
      css = Theme.css(accent: "#FF2BD1", not_a_token: "red", background: "blue")
      assert_includes css, "--accent:"
      refute_includes css, "not-a-token"
      refute_includes css, "--background:"
    end

    # This lands inside a <style> block. There is no escaping that makes
    # arbitrary input safe there, so the value shape is constrained instead.
    def test_values_that_could_escape_the_declaration_are_rejected
      [
        "#fff; } body { display:none",        # close the rule, open another
        "red; --text: red",                    # smuggle a second declaration
        "#fff /* comment */",                  # comment out what follows
        "url(http://evil.test/x.css)@import",  # at-rule
        "expression(alert(1))<script>",        # angle brackets
        "\\65 xpression"                       # CSS escape sequence
      ].each do |bad|
        assert_nil Theme.css(accent: bad), "should reject: #{bad.inspect}"
      end
    end

    def test_a_rejected_value_does_not_discard_its_valid_siblings
      css = Theme.css(accent: "#FF2BD1", bg: "red; } evil {")
      assert_includes css, "--accent: #FF2BD1;"
      refute_includes css, "evil"
    end

    def test_absurdly_long_values_are_rejected
      assert_nil Theme.css(accent: "#" + ("a" * 200))
    end

    def test_functional_colour_values_are_allowed
      css = Theme.css(panel: "rgba(20, 10, 36, 0.85)", sans: '"Inter", system-ui, sans-serif')
      assert_includes css, "--panel: rgba(20, 10, 36, 0.85);"
      assert_includes css, "--sans:"
    end

    def test_the_shipped_preset_is_valid
      css = Theme.css(Theme::PRESETS[:cyberpunk])
      assert_includes css, "--accent: #FF2BD1;"
      assert_includes css, ':root:not([data-theme="light"])'
    end

    # 150-odd hand-typed hex values, and a malformed one is *dropped* rather than
    # raised — the shape check has no way to tell a typo from a deliberate
    # omission. So assert every shipped palette emits every token it claims: a
    # mistyped swatch goes missing here rather than in someone's browser.
    def test_every_shipped_palette_emits_every_token
      Theme::PRESETS.each do |name, config|
        Theme.normalize(config).each do |mode, tokens|
          css = Theme.css(mode => tokens)
          tokens.each_key do |token|
            assert_includes css, "--#{token.to_s.tr("_", "-")}:",
              "#{name}/#{mode} silently dropped #{token} — check the value"
          end
        end
      end
    end

    # Ten of the eleven ship both modes, so picking a palette is never a choice
    # to also give up light mode. Cyberpunk is the deliberate exception.
    def test_every_palette_but_cyberpunk_covers_both_modes
      Theme::PRESETS.except(:cyberpunk).each do |name, config|
        css = Theme.css(config)
        assert_includes css, ':root:not([data-theme="light"])', "#{name} has no dark mode"
        assert_includes css, ':root[data-theme="light"]', "#{name} has no light mode"
      end
      assert_equal :dark, Theme.only_mode(Theme::PRESETS[:cyberpunk])
    end

    # An accent that reads as a status is worse than a duller accent.
    def test_no_accent_collides_with_a_status_colour
      each_palette_mode do |label, t|
        refute_includes t.values_at(:good, :warn, :crit), t[:accent],
          "#{label}: accent is indistinguishable from a status colour"
      end
    end

    # Every project names its swatches differently, so these are the structural
    # invariants the role mapping has to satisfy however the source is organised:
    # a card must be visible against the page, a pill against the card, and a
    # card border against the card. Getting one wrong makes a whole surface vanish.
    def test_surfaces_stay_distinguishable
      each_palette_mode do |label, t|
        refute_equal t[:bg], t[:panel], "#{label}: cards invisible against the page"
        refute_equal t[:panel], t[:panel_2], "#{label}: pills invisible on cards"
        refute_equal t[:panel], t[:line_soft], "#{label}: card borders invisible"
      end
    end

    # The floors these palettes were mapped to. Without this a palette can look
    # perfectly plausible as a list of hex values and be unreadable on screen —
    # Nord's own comment grey lands at 1.36:1 on its own panel, which is how
    # that one got caught.
    FLOORS = { text: 4.5, muted: 2.8, faint: 2.4, accent: 3.0 }.freeze

    # Contrast floors keep type readable; these keep the surfaces from *reading*
    # wrong, which is a different failure and the one that gets noticed first.
    # The shipped theme is the reference: borders at 1.20 (dark) / 1.31 (light),
    # dividers at 1.08 / 1.20, cards 1.05 / 1.08 off the page. Mapping `line` one
    # surface step too far is the easy mistake — it put Nord's light border at
    # 6.4:1 and Rosé Pine's dark border at 3.2:1, which is a hard outline round
    # every button rather than a theme.
    #
    # Solarized is the documented exception: it ships exactly three steps per
    # mode, and the gap from base02 to base01 is simply that wide. Its dividers
    # are in band; only its button borders are not.
    HARSH_LINE_ALLOWED = %i[solarized kanagawa].freeze

    def test_borders_and_dividers_stay_in_band
      each_palette_mode do |label, t|
        name = label.split("/").first.to_sym
        ceiling = HARSH_LINE_ALLOWED.include?(name) ? 2.6 : 1.85
        assert_operator contrast(t[:line], t[:panel]), :<=, ceiling,
          "#{label}: borders are a hard outline, not a theme"
        assert_operator contrast(t[:line_soft], t[:panel]), :<=, 1.4,
          "#{label}: card dividers are drawn as hard lines"
        assert_operator contrast(t[:panel], t[:bg]), :>=, 1.04,
          "#{label}: cards do not lift off the page"
      end
    end

    def test_every_palette_clears_its_contrast_floors
      each_palette_mode do |label, t|
        FLOORS.each do |token, floor|
          assert_operator contrast(t[token], t[:panel]), :>=, floor, "#{label}: #{token} on panel"
        end
        assert_operator contrast(t[:muted], t[:panel_2]), :>=, 2.8, "#{label}: pill text on pill"
      end
    end

    def test_string_keys_work_the_same_as_symbols
      assert_includes Theme.css("accent" => "#FF2BD1"), "--accent: #FF2BD1;"
    end

    private

    def each_palette_mode
      Theme::PRESETS.each do |name, config|
        Theme.normalize(config).each do |mode, tokens|
          yield "#{name}/#{mode}", tokens.symbolize_keys
        end
      end
    end

    def contrast(a, b)
      l1, l2 = relative_luminance(a), relative_luminance(b)
      l1, l2 = l2, l1 if l1 < l2
      (l1 + 0.05) / (l2 + 0.05)
    end

    # Ignores any alpha channel: cyberpunk's panel_3 carries one, and a
    # translucent value has no defined contrast against an unknown backdrop.
    def relative_luminance(hex)
      r, g, b = hex.delete("#")[0, 6].scan(/../).map do |pair|
        c = pair.to_i(16) / 255.0
        c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4
      end
      (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
    end
  end

  # Palettes a viewer picks in their own browser. The browser stores which
  # palette by name; the colours only ever come from server-side config, so a
  # tampered localStorage value can select nothing that was not already vetted.
  class ThemeSelectableTest < ActiveSupport::TestCase
    def teardown
      RoundhouseUi.themes = Theme::PRESETS
      RoundhouseUi.allow_theme_selection = true
    end

    def test_the_shipped_presets_are_on_offer_by_default
      assert_includes Theme.selectable.keys, :cyberpunk
    end

    def test_an_install_can_withdraw_the_offer
      RoundhouseUi.allow_theme_selection = false
      assert_empty Theme.selectable
      assert_nil Theme.selectable_css
    end

    def test_nothing_configured_emits_nothing
      RoundhouseUi.themes = nil
      assert_empty Theme.selectable
      assert_nil Theme.selectable_css
    end

    # One attribute on :root switches the whole palette, which is why the
    # browser only ever has to remember a name.
    def test_a_palette_is_scoped_to_its_own_attribute
      css = Theme.selectable_css(cyberpunk: { dark: { bg: "#0A0511" } })
      assert_includes css, ':root[data-rh-palette="cyberpunk"]:not([data-theme="light"]) { --bg: #0A0511; }'
    end

    def test_a_flat_palette_applies_to_both_modes
      css = Theme.selectable_css(plain: { accent: "#FF2BD1" })
      assert_includes css, ':root[data-rh-palette="plain"] { --accent: #FF2BD1; }'
    end

    def test_each_palette_gets_its_own_block
      css = Theme.selectable_css(one: { accent: "#111111" }, two: { accent: "#222222" })
      assert_includes css, 'data-rh-palette="one"'
      assert_includes css, 'data-rh-palette="two"'
    end

    # The name lands in a CSS attribute selector, so it is constrained for the
    # same reason the values are — a quote in a palette name would close the
    # selector and everything after it is arbitrary CSS.
    def test_palette_names_that_could_escape_the_selector_are_rejected
      css = Theme.selectable_css("evil\"] { display:none } :root[x=\"" => { accent: "#FF2BD1" })
      assert_nil css
    end

    def test_a_rejected_name_does_not_take_its_valid_siblings_with_it
      css = Theme.selectable_css("bad name!" => { accent: "#111111" }, ok: { accent: "#222222" })
      assert_includes css, 'data-rh-palette="ok"'
      refute_includes css, "bad name"
    end

    # The menu and the CSS have to agree, or a host typo becomes a dropdown
    # option that silently does nothing when picked.
    def test_a_rejected_name_is_not_offered_in_the_menu_either
      offered = Theme.selectable("bad name!" => { accent: "#111111" }, ok: { accent: "#222222" })
      assert_equal [ :ok ], offered.keys
    end

    # Values go through the same allowlist as a host theme: a palette is config,
    # and config is not trusted with arbitrary CSS.
    def test_palette_values_are_shape_checked_too
      css = Theme.selectable_css(sneaky: { accent: "red; } body { display:none" })
      assert_nil css
    end

    def test_unknown_tokens_in_a_palette_are_ignored
      css = Theme.selectable_css(p1: { accent: "#FF2BD1", not_a_token: "red" })
      assert_includes css, "--accent:"
      refute_includes css, "not-a-token"
    end
  end

  class ThemeRenderingTest < ActionDispatch::IntegrationTest
    def teardown = RoundhouseUi.theme = nil

    def test_a_configured_theme_reaches_the_page
      RoundhouseUi.theme = { accent: "#FF2BD1" }
      get "/roundhouse/queues"
      assert_response :success
      assert_match "--accent: #FF2BD1;", @response.body
    end

    # Overrides must come after the shipped :root blocks, or they lose.
    def test_overrides_are_emitted_after_the_defaults
      RoundhouseUi.theme = { accent: "#FF2BD1" }
      get "/roundhouse/queues"
      assert_operator @response.body.index("--accent: #FF2BD1;"), :>,
        @response.body.index("--accent:#6E8BFF"),
        "the host override has to come last to win"
    end

    def test_no_theme_changes_nothing
      get "/roundhouse/queues"
      assert_response :success
      assert_match "--accent:#6E8BFF", @response.body
    end
  end
end
