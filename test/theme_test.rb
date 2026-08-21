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

    def test_string_keys_work_the_same_as_symbols
      assert_includes Theme.css("accent" => "#FF2BD1"), "--accent: #FF2BD1;"
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
