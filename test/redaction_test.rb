require "test_helper"

module RoundhouseUi
  class RedactionTest < ActiveSupport::TestCase
    def teardown = RoundhouseUi.redact_args = []

    def test_masks_matching_keys_deeply
      patterns = %w[password token]
      out = Redaction.apply([ { "user" => "a", "password" => "x", "meta" => { "api_token" => "y", "ok" => 1 } } ], patterns)

      assert_equal "a", out[0]["user"]
      assert_equal Redaction::MASK, out[0]["password"]
      assert_equal Redaction::MASK, out[0]["meta"]["api_token"]
      assert_equal 1, out[0]["meta"]["ok"]
    end

    def test_is_a_noop_with_no_patterns
      assert_equal [ { "password" => "x" } ], Redaction.apply([ { "password" => "x" } ], [])
    end
  end
end
