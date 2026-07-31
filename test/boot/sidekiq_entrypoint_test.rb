require "minitest/autorun"
require "open3"
require "rbconfig"

class SidekiqEntrypointTest < Minitest::Test
  def test_boots_the_existing_sidekiq_backend
    script = <<~'RUBY'
      require "bundler/setup"
      require "roundhouse_ui"

      raise "Sidekiq was not loaded" unless defined?(Sidekiq)
      raise "wrong backend" unless RoundhouseUi.backend.is_a?(RoundhouseUi::Backends::Sidekiq)
    RUBY

    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I#{File.expand_path("../../lib", __dir__)}", "-e", script
    )

    assert status.success?, stderr
  end
end
