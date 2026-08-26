require "test_helper"

module RoundhouseUi
  # The ⌘K palette interpolated icon markup into a JS string. `Icons.markup` is
  # deliberately NOT html_safe — the `icon` helper is what calls .html_safe — so
  # ERB escaped it, and because a <script> body is raw text to the parser, every
  # palette row rendered `&lt;svg viewBox=&quot;…` as literal characters.
  #
  # It broke silently the day icons stopped being single Unicode glyphs, and no
  # test noticed because nothing looked at what reached the browser.
  class ScriptEscapingTest < ActionDispatch::IntegrationTest
    ENTITIES = %w[&lt; &gt; &quot; &#39; &amp;].freeze

    def scripts(body)
      body.scan(/<script\b[^>]*>(.*?)<\/script>/m).flatten
    end

    def test_no_escaped_markup_reaches_a_script_body
      # An HTML entity inside a <script> is never what anyone meant: the parser
      # treats script content as raw text, so it arrives in the string verbatim.
      get "/roundhouse/queues"
      assert_response :success

      offenders = scripts(response.body).flat_map do |js|
        ENTITIES.filter_map do |ent|
          n = js.scan(ent).size
          "#{ent} x#{n}" if n.positive?
        end
      end

      assert_empty offenders,
        "HTML entities inside a <script>: #{offenders.join(', ')}. Something " \
        "non-html_safe was interpolated into JavaScript; it will be read as " \
        "literal characters, not markup."
    end

    def test_the_palette_carries_icon_names_not_markup
      get "/roundhouse/queues"
      js = scripts(response.body).find { |s| s.include?("var CMDS") }
      refute_nil js, "could not find the palette command list"

      refute_match(/ico(n)?:\s*"\s*<svg/, js, "raw SVG markup in a JS string")
      assert_match(/ico:\s*"\w+"/, js, "the palette should carry icon names")
    end

    def test_the_icon_store_renders_real_svg_for_every_shipped_icon
      get "/roundhouse/queues"
      store = response.body[/<template id="rh-ico-store">.*?<\/template>/m].to_s
      refute_empty store, "the palette has no icon store to clone from"

      assert_equal RoundhouseUi::Icons::PATHS.size, store.scan(/data-ico="/).size,
        "the store must hold every shipped icon, or the palette silently loses one"
      assert_equal RoundhouseUi::Icons::PATHS.size, store.scan(/<svg /).size,
        "an entry in the store is not a real <svg> element"
      refute_match(/&lt;svg/, store, "the store is escaping its own markup")
    end
  end
end
