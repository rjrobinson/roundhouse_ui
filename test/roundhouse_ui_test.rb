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
end
