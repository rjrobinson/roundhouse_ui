require "test_helper"

module RoundhouseUi
  # Docs drift silently: nothing fails when an option is renamed and the README
  # keeps naming the old one. These checks are deterministic and cheap — they
  # answer "do the things the docs name still exist", which is where most real
  # drift shows up, and which no amount of prose review reliably catches.
  #
  # They cannot answer "is the explanation still true". That needs a reader.
  class DocumentationTest < ActiveSupport::TestCase
    README = Rails.root.join("../../README.md").expand_path
    # Options shown in docs but deliberately not accessors on RoundhouseUi.
    NOT_CONFIG = %w[configure].freeze

    def readme = @readme ||= File.read(README)

    def test_the_readme_is_where_we_think_it_is
      assert File.exist?(README), "README not found at #{README}"
    end

    # Every `c.some_option =` / `RoundhouseUi.some_option =` in the docs must be
    # a real accessor. Renaming a setting without updating the README is the
    # single most common way this file earns its keep.
    def test_every_documented_config_option_exists
      documented = readme.scan(/(?:^|\s)(?:c|RoundhouseUi)\.([a-z_]+)\s*=/).flatten.uniq - NOT_CONFIG
      assert_operator documented.size, :>, 10, "expected the README to document many options"

      missing = documented.reject { |opt| RoundhouseUi.respond_to?("#{opt}=") }
      assert_empty missing, "README documents settings that no longer exist: #{missing.join(", ")}"
    end

    # The reverse: a setting nobody documented is a setting nobody will use.
    def test_every_config_option_is_documented
      accessors = RoundhouseUi.singleton_methods.grep(/=\z/).map { |m| m.to_s.chomp("=") }
      internal = %w[backend config theme themes]  # covered by prose sections, not the table
      undocumented = accessors.reject { |a| internal.include?(a) || readme.include?(a) }
      assert_empty undocumented, "these settings are undocumented: #{undocumented.join(", ")}"
    end

    # Constants and factory methods the docs tell people to call.
    def test_documented_entry_points_resolve
      readme.scan(/RoundhouseUi::([A-Z]\w+)(?:::([A-Z_]+)\b|\.([a-z_]+))?/).each do |mod, const, meth|
        target = "RoundhouseUi::#{mod}".safe_constantize
        assert target, "README references RoundhouseUi::#{mod}, which does not exist"
        assert target.const_defined?(const), "#{mod}::#{const} is gone" if const
        assert target.respond_to?(meth), "#{mod}.#{meth} is gone" if meth
      end
    end

    # Paths the README links to, so a moved file does not leave a dead link.
    def test_linked_repo_files_exist
      root = Rails.root.join("../..").expand_path
      readme.scan(%r{\]\((docs/[\w./-]+|lib/[\w./-]+)\)}).flatten.uniq.each do |path|
        assert File.exist?(root.join(path)), "README links to #{path}, which does not exist"
      end
    end

    # Token names in the theming section have to match the allowlist, or someone
    # follows the docs and silently gets nothing.
    def test_documented_theme_tokens_are_real
      section = readme[/Available tokens:(.*?)\n\n/m]
      assert section, "the theming section no longer lists its tokens"
      documented = section.scan(/`(\w+)`/).flatten.map(&:to_sym)
      unknown = documented - RoundhouseUi::Theme::TOKENS
      assert_empty unknown, "README lists theme tokens that are not in the allowlist: #{unknown.join(", ")}"
      missing = RoundhouseUi::Theme::TOKENS - documented
      assert_empty missing, "these theme tokens are undocumented: #{missing.join(", ")}"
    end

    # Preset names get quoted in docs and copied into initializers.
    def test_documented_presets_exist
      readme.scan(/PRESETS\[:(\w+)\]/).flatten.uniq.each do |name|
        assert RoundhouseUi::Theme::PRESETS.key?(name.to_sym),
          "README references a preset that no longer ships: #{name}"
      end
    end
  end
end
