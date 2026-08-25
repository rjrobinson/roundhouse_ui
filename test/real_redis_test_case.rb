require "test_helper"

module RoundhouseUi
  # Base class for the tests that run against a real Redis.
  #
  # Everything else in this suite runs on FakeRedis — a hand-written emulator in
  # test_helper.rb where HGET always returns nil, ZADD discards the score and
  # SSCAN returns the whole set in one pass. That is fine for exercising our
  # logic and useless for the question these tests ask, which is whether Redis
  # behaves the way the code assumes. Snapshot → restore, enforced pause and
  # bulk-on-a-filter are made of Redis semantics; asserting them against a fake
  # asserts the fake.
  #
  # These are opt-in, and deliberately have no default URL. They FLUSHDB the
  # database they are pointed at, and a developer's local Redis is full of other
  # projects' data — so nothing runs unless someone names a target:
  #
  #   ROUNDHOUSE_TEST_REDIS_URL=redis://localhost:6379/10 bin/rails test
  #
  # CI sets that plus ROUNDHOUSE_REQUIRE_REAL_REDIS=1, which turns a skip into a
  # failure. Without it these would quietly skip forever and the coverage would
  # be imaginary — which is the failure mode this whole file exists to fix.
  class RealRedisTestCase < ActiveSupport::TestCase
    self.fake_redis = false

    URL = ENV["ROUNDHOUSE_TEST_REDIS_URL"]
    REQUIRED = ENV["ROUNDHOUSE_REQUIRE_REAL_REDIS"].present?

    def setup
      require_real_redis!
      flush!
      RoundhouseUi.read_only = false
    end

    def teardown
      # Only if setup actually connected. The first version of this guarded on
      # "was a URL configured", which is not the same question: when setup
      # refused a URL before connecting, teardown still ran and flushed whatever
      # Sidekiq's *default* connection happened to be — database 0 on a developer's
      # machine. The check written to prove database 0 was safe is what wiped it.
      flush! if @connected
      RoundhouseUi.read_only = false
    end

    private

    # Ask the connection where it actually is before deleting anything. Reading
    # the configuration cannot answer that: Sidekiq falls back to localhost/0
    # when it was never configured, and the configuration says nothing about
    # which connection this block was handed.
    def flush!
      Sidekiq.redis do |conn|
        actual = conn.call("CLIENT", "INFO").to_s[/\bdb=(\d+)/, 1]
        unless actual == expected_database
          raise "refusing to FLUSHDB: connected to db=#{actual.inspect}, " \
                "expected db=#{expected_database.inspect} from #{URL}"
        end

        conn.call("FLUSHDB")
      end
    end

    def expected_database
      path = URI.parse(URL).path.to_s.delete_prefix("/")
      path.empty? ? "0" : path
    end

    def require_real_redis!
      unless URL
        message = "set ROUNDHOUSE_TEST_REDIS_URL to run the real-Redis tests"
        REQUIRED ? flunk("#{message} — required in this environment") : skip(message)
      end

      # Database 0 is where everything else on a developer's machine lives, and
      # setup flushes whatever it is pointed at.
      flunk "refusing to run against database 0 — point at a scratch database" if database_zero?

      @connected ||= connect!
    end

    def database_zero?
      path = URI.parse(URL).path.to_s
      path.empty? || path == "/" || path == "/0"
    end

    def connect!
      Sidekiq.configure_client { |config| config.redis = { url: URL } }
      Sidekiq.redis { |conn| conn.call("PING") }
      true
    rescue StandardError => e
      flunk "ROUNDHOUSE_TEST_REDIS_URL is set but unreachable (#{e.class}: #{e.message})"
    end
  end
end
