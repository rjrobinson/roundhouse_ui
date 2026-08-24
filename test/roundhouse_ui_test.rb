require "test_helper"

class RoundhouseUiTest < ActiveSupport::TestCase
  def teardown
    RoundhouseUi.read_only = false
  end

  test "it has a version number" do
    assert RoundhouseUi::VERSION
  end

  test "read_only defaults to false" do
    assert_equal false, RoundhouseUi.read_only
  end

  test "configure yields self for block configuration" do
    RoundhouseUi.configure { |c| c.read_only = true }
    assert_equal true, RoundhouseUi.read_only
  end

  # ActiveJob-on-Sidekiq puts the adapter wrapper in item["class"]; display,
  # search, grouping and APM links all have to resolve past it to the same
  # string, so the unwrap is shared rather than repeated.
  WRAPPER = "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper".freeze

  test "unwrapped_class prefers the wrapped class" do
    assert_equal "RealJob", RoundhouseUi.unwrapped_class(WRAPPER, { "wrapped" => "RealJob" })
  end

  test "unwrapped_class falls back to the given class" do
    assert_equal "PlainWorker", RoundhouseUi.unwrapped_class("PlainWorker", { "class" => "PlainWorker" })
  end

  # Solid Queue's synthetic item has no "wrapped" key, and callers pass {} where
  # no payload is available (grouped errors) — neither may raise.
  test "unwrapped_class tolerates an item with nothing to unwrap" do
    [ {}, nil, "not a hash", [] ].each do |item|
      assert_equal "PlainWorker", RoundhouseUi.unwrapped_class("PlainWorker", item),
        "item #{item.inspect} should fall through to klass"
    end
  end

  test "unwrapped_class returns a String even for a symbol class" do
    assert_equal "RealJob", RoundhouseUi.unwrapped_class(WRAPPER, { "wrapped" => :RealJob })
  end

  test "unwrapped_class returns nil when there is nothing to name" do
    assert_nil RoundhouseUi.unwrapped_class(nil, {})
  end

  # Applying it twice must be a no-op — grouped errors resolve tags from an
  # already-unwrapped class with an empty item.
  test "unwrapped_class is idempotent" do
    once = RoundhouseUi.unwrapped_class(WRAPPER, { "wrapped" => "RealJob" })
    assert_equal once, RoundhouseUi.unwrapped_class(once, {})
  end
end
