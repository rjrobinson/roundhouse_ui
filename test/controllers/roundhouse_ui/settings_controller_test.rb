require "test_helper"

module RoundhouseUi
  # The Settings page is deliberately server-stateless: it renders the controls
  # and the host's defaults, and the browser owns every value. So what is worth
  # testing is that the page offers exactly what the install permits — nothing
  # a viewer picks here can be stored server-side to assert on.
  class SettingsControllerTest < ActionDispatch::IntegrationTest
    def teardown
      RoundhouseUi.themes = Theme::PRESETS
      RoundhouseUi.allow_theme_selection = true
      RoundhouseUi.poll_interval = 5
    end

    def test_renders_every_control
      get "/roundhouse/settings"
      assert_response :success
      %w[rh-set-theme rh-set-palette rh-set-width rh-set-poll rh-set-reset].each do |id|
        assert_match %(id="#{id}"), @response.body, "missing the #{id} control"
      end
    end

    def test_offers_each_configured_palette_by_name
      RoundhouseUi.themes = { cyberpunk: Theme::PRESETS[:cyberpunk], midnight: { dark: { bg: "#000000" } } }
      get "/roundhouse/settings"
      assert_match %(value="cyberpunk"), @response.body
      assert_match %(value="midnight"), @response.body
    end

    # A dark-only palette is inert in light mode, so the menu has to say which
    # mode it covers rather than looking broken when nothing happens.
    def test_a_single_mode_palette_says_so
      RoundhouseUi.themes = { loud: { dark: { accent: "#FF2BD1" } }, both: { dark: { accent: "#111111" }, light: { accent: "#222222" } } }
      get "/roundhouse/settings"
      assert_match "Loud — dark only", @response.body
      assert_match ">Both</option>", @response.body
    end

    # Roundhouse has no prefers-color-scheme block, so "match the system" is not
    # a state it can offer — unset renders dark, and the menu must not imply
    # otherwise.
    def test_appearance_does_not_promise_to_follow_the_system
      get "/roundhouse/settings"
      refute_match "Match system", @response.body
      assert_match "does not follow the operating system", @response.body
    end

    # An operator recolouring a production console is a real objection, so an
    # install can withdraw the control rather than only the palettes.
    def test_palette_selection_disappears_when_the_install_forbids_it
      RoundhouseUi.allow_theme_selection = false
      get "/roundhouse/settings"
      assert_response :success
      refute_match %(id="rh-set-palette"), @response.body
      assert_match "Palette selection is disabled", @response.body
    end

    def test_no_palette_control_when_the_host_configured_none
      RoundhouseUi.themes = nil
      get "/roundhouse/settings"
      assert_response :success
      refute_match %(id="rh-set-palette"), @response.body
    end

    # "App default" has to say what the default actually is, or the option is a
    # guess. The poll runs this app's auth and routing on every tick, so the
    # number is the host's business.
    def test_names_the_hosts_poll_interval
      RoundhouseUi.poll_interval = 17
      get "/roundhouse/settings"
      assert_match "App default (17s)", @response.body
    end

    def test_reachable_from_the_nav
      get "/roundhouse/queues"
      assert_match "/roundhouse/settings", @response.body
    end

    # Palette CSS has to be emitted on every page, not just Settings — a viewer
    # picks a palette once and expects it everywhere.
    def test_palette_css_is_emitted_on_other_pages
      RoundhouseUi.themes = { midnight: { dark: { bg: "#010203" } } }
      get "/roundhouse/queues"
      assert_match ':root[data-rh-palette="midnight"]', @response.body
    end

    # A palette must beat a host theme, or a viewer's pick would silently lose
    # on exactly the installs that bothered to configure colours.
    def test_a_palette_outranks_a_host_theme
      RoundhouseUi.theme = { accent: "#111111" }
      RoundhouseUi.themes = { midnight: { accent: "#222222" } }
      get "/roundhouse/queues"
      assert_operator @response.body.index("--accent: #222222;"), :>,
        @response.body.index("--accent: #111111;"),
        "the selectable palette has to be emitted after the host theme"
    ensure
      RoundhouseUi.theme = nil
    end
  end
end
