require "test_helper"

module RoundhouseUi
  # Configuration is global, so a test that sets it and forgets to reset leaks into
  # whatever runs next — and it surfaces in an unrelated test, which is the hardest
  # kind to trace. Nine test files were leaking `job_tags`, and a stray dummy-app
  # initializer was leaking it too; the symptom was JobsControllerTest failing on a
  # fake entry that has no #klass.
  #
  # test_helper captures every setting before each test and restores it after. What is
  # asserted here is that the net COVERS the surface — the restore itself cannot be
  # proven in-process, because Rails forces random test order and an ordered pair
  # (leak, then assert-clean) passes or fails on luck.
  class ConfigIsolationTest < ActiveSupport::TestCase
    NET = ActiveSupport::TestCase::RESETTABLE_CONFIG

    def test_every_setting_the_net_names_exists
      missing = NET.reject do |name|
        RoundhouseUi.respond_to?(name) && RoundhouseUi.respond_to?("#{name}=")
      end
      assert_empty missing,
        "test_helper restores #{missing.join(', ')}, which RoundhouseUi does not expose — " \
        "a rename dropped it from the net silently."
    end

    # The one that earns its place: it found snapshot_store and observability missing.
    def test_the_net_covers_every_writable_setting
      writable = RoundhouseUi.singleton_class.instance_methods(false)
                             .grep(/=$/).map { |m| m.to_s.chomp("=").to_sym }
      uncovered = writable - NET
      assert_empty uncovered,
        "#{uncovered.join(', ')} can be set by a test and is not restored afterwards. " \
        "Add it to RESETTABLE_CONFIG in test_helper.rb."
    end

    def test_the_harness_restores_what_it_captured
      RoundhouseUi.job_tags = nil
      captured = NET.to_h { |name| [ name, RoundhouseUi.public_send(name) ] }
      RoundhouseUi.job_tags = ->(klass:, item:) { { squad: "leak" } }
      RoundhouseUi.poll_interval = 999

      captured.each { |name, value| RoundhouseUi.public_send("#{name}=", value) }

      assert_nil RoundhouseUi.job_tags
      refute_equal 999, RoundhouseUi.poll_interval
    end
  end
end
