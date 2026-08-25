require "test_helper"

module RoundhouseUi
  # warn_once was named for what it was supposed to do. A resolver that raises
  # raises for every entry in a scan, so one broken lambda wrote a line per job.
  class WarnOnceTest < ActiveSupport::TestCase
    class Collector
      attr_reader :lines
      def initialize = @lines = []
      def warn(message) = lines << message
      def method_missing(*) = nil
      def respond_to_missing?(*) = true
    end

    def setup
      RoundhouseUi.instance_variable_set(:@warned, nil)
      @collector = Collector.new
      @original_logger = Rails.logger
      Rails.logger = @collector
    end

    def teardown
      Rails.logger = @original_logger
      RoundhouseUi.instance_variable_set(:@warned, nil)
      RoundhouseUi.job_tags = nil
      RoundhouseUi.job_tags_per_job = false
    end

    def test_a_resolver_that_fails_on_every_entry_logs_one_line
      RoundhouseUi.job_tags = ->(klass:, item:) { raise "boom" }
      RoundhouseUi.job_tags_per_job = true

      200.times { |i| Tags.for(klass: "Widget", item: { "jid" => "j#{i}" }) }

      assert_equal 1, @collector.lines.size,
        "a 200-entry scan wrote #{@collector.lines.size} identical warnings; " \
        "a log that repeats itself a thousand times is a log nobody reads"
      assert_match(/job_tags resolver failed for Widget: boom/, @collector.lines.first)
    end

    def test_a_genuinely_different_failure_is_not_swallowed
      RoundhouseUi.warn_once("first thing broke")
      RoundhouseUi.warn_once("first thing broke")
      RoundhouseUi.warn_once("a second, different thing broke")

      assert_equal 2, @collector.lines.size,
        "deduplication must be per message, not a global mute"
    end

    def test_the_memo_cannot_grow_without_bound
      # A resolver whose message carries an id produces a new string every time.
      (RoundhouseUi::WARN_MEMO_CAP * 2).times { |i| RoundhouseUi.warn_once("failed on job #{i}") }

      memo = RoundhouseUi.instance_variable_get(:@warned)
      assert_operator memo.size, :<=, RoundhouseUi::WARN_MEMO_CAP,
        "the memo grew past its cap; a varying message would leak memory for the process's life"
    end

    def test_runbooks_shares_the_one_implementation
      RoundhouseUi.job_runbooks = ->(klass:, item:) { raise "boom" }
      50.times { |i| Runbooks.for("Widget", { "jid" => "j#{i}" }) }

      assert_equal 1, @collector.lines.size
    ensure
      RoundhouseUi.job_runbooks = nil
    end
  end
end
