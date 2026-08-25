require "test_helper"

module RoundhouseUi
  class IconsTest < ActiveSupport::TestCase
    def teardown = RoundhouseUi.icons = :svg

    def test_default_is_inline_svg
      markup = Icons.markup(:queues)
      assert markup.start_with?("<svg "), markup.to_s[0, 40]
      assert_includes markup, 'stroke="currentColor"', "icons must inherit the surrounding colour"
      assert_includes markup, 'aria-hidden="true"', "decorative icons must not be announced"
    end

    # No name may be missing: a nav item with no icon is a visibly broken row.
    def test_every_icon_referenced_by_the_ui_exists
      %i[dashboard queues retries dead errors busy metrics snapshots audit settings
         scheduled workers capsules redis enqueue width theme pause delete ok warn
         stalled search runbook trace_out].each do |name|
        assert Icons::PATHS.key?(name), "missing SVG for :#{name}"
        assert Icons::FONT_AWESOME.key?(name), "missing FontAwesome mapping for :#{name}"
      end
    end

    def test_font_awesome_mode_emits_class_names
      RoundhouseUi.icons = :font_awesome
      assert_equal "fa-solid fa-layer-group", Icons.markup(:queues)
    end

    def test_a_hash_overrides_per_icon
      RoundhouseUi.icons = { queues: "my-queues" }
      assert_equal "my-queues", Icons.markup(:queues)
      assert_nil Icons.markup(:dead), "an unmapped name in Hash mode renders nothing"
    end

    def test_string_keys_work_in_a_hash
      RoundhouseUi.icons = { "queues" => "my-queues" }
      assert_equal "my-queues", Icons.markup(:queues)
    end

    # A typo in a host's mapping must not take a page down.
    def test_an_unknown_name_renders_nothing
      assert_nil Icons.markup(:no_such_icon)
      assert_nil Icons.markup(nil)
    end

    # Every path is our own constant, so it is marked html_safe. That is only
    # true while nothing host-supplied can reach it.
    def test_no_shipped_path_contains_markup_that_could_escape_the_svg
      Icons::PATHS.each do |name, path|
        refute_match(/<\/svg|<script|on\w+=/i, path, "#{name} contains markup that must not be there")
      end
    end
  end

  class IconRenderingTest < ActionDispatch::IntegrationTest
    def teardown = RoundhouseUi.icons = :svg

    def test_nav_renders_inline_svg_by_default
      get "/roundhouse/queues"
      assert_response :success
      assert_select "#rh-rail .rh-nav .rh-ico svg", minimum: 5
    end

    # The class name comes from config, so it must be escaped rather than trusted.
    def test_a_host_supplied_class_name_is_escaped
      RoundhouseUi.icons = { queues: 'x" onload="alert(1)' }
      get "/roundhouse/queues"
      assert_response :success
      refute_match 'onload="alert(1)"', @response.body
    end

    def test_font_awesome_mode_emits_no_svg_in_the_nav
      RoundhouseUi.icons = :font_awesome
      get "/roundhouse/queues"
      assert_select "#rh-rail .rh-nav i.fa-solid", minimum: 3
      assert_select "#rh-rail .rh-nav svg", count: 0
    end
  end
end
