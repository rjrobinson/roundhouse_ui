require "test_helper"

module RoundhouseUi
  class RedisControllerTest < ActionDispatch::IntegrationTest
    def test_renders_redis_health_from_info
      get "/roundhouse/redis"

      assert_response :success
      assert_match "allkeys-lru", @response.body          # eviction policy surfaced
      assert_match "evicted and silently lost", @response.body # the headline warning
      assert_match "1.00M", @response.body                # memory
      assert_match "1,234", @response.body                # db0 keys, delimited
      assert_match "v7.2.0", @response.body               # version
    end
  end
end
