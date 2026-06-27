# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
require "rails/test_help"

class ActiveSupport::TestCase
  # Temporarily replace a class method, restoring it after the block.
  # (minitest/mock's #stub won't load under the bundled minitest here.)
  def stub_method(klass, name, retval)
    original = klass.method(name)
    klass.define_singleton_method(name) { |*_args, **_kwargs| retval }
    yield
  ensure
    klass.define_singleton_method(name, original)
  end

  # In-memory stand-in for the connection Sidekiq.redis yields, so tests that
  # touch the pause registry need no running Redis.
  class FakeRedis
    INFO_FIXTURE = <<~INFO
      # Server
      redis_version:7.2.0
      role:master
      uptime_in_seconds:90000
      connected_clients:42
      blocked_clients:5
      rejected_connections:0
      maxclients:10000
      instantaneous_ops_per_sec:1200
      total_commands_processed:999999
      used_memory:1048576
      used_memory_human:1.00M
      maxmemory:4194304
      maxmemory_policy:allkeys-lru
      mem_fragmentation_ratio:1.20
      evicted_keys:7
      expired_keys:100
      keyspace_hits:9000
      keyspace_misses:1000
      db0:keys=1234,expires=10
    INFO

    def initialize
      @sets = Hash.new { |h, k| h[k] = [] }
      @lists = Hash.new { |h, k| h[k] = [] }
      @strings = {}
    end

    def call(cmd, *args)
      case cmd.to_s.upcase
      when "SADD"      then key, m = args; @sets[key] |= [ m ]; 1
      when "SREM"      then key, m = args; @sets[key].delete(m); 1
      when "SISMEMBER" then key, m = args; @sets[key].include?(m) ? 1 : 0
      when "SMEMBERS"  then @sets[args[0]].dup
      when "SET"       then @strings[args[0]] = args[1]; "OK"
      when "GET"       then @strings[args[0]]
      when "EXISTS"    then (@strings.key?(args[0]) || @sets.key?(args[0])) ? 1 : 0
      when "DEL"       then args.each { |k| @strings.delete(k); @sets.delete(k) }; 1
      when "RPUSH"     then key, *vals = args; @lists[key].concat(vals); @lists[key].size
      when "LPUSH"     then key, *vals = args; vals.each { |v| @lists[key].unshift(v) }; @lists[key].size
      when "LTRIM"     then key, a, b = args; @lists[key] = (@lists[key][a..b] || []); "OK"
      when "LRANGE"    then key, a, b = args; (@lists[key][a..b] || [])
      when "LLEN"      then @lists[args[0]].size
      when "INFO"      then INFO_FIXTURE
      when "EXPIRE"    then 1
      else raise "FakeRedis: unexpected command #{cmd}"
      end
    end
  end

  def with_fake_redis
    fake = FakeRedis.new
    original = Sidekiq.method(:redis)
    Sidekiq.define_singleton_method(:redis) { |&blk| blk.call(fake) }
    yield fake
  ensure
    Sidekiq.define_singleton_method(:redis, original)
  end

  # Install a default fake Redis around every test so nothing (e.g. the audit
  # after_action on POSTs) ever touches a real Redis. before_setup/after_teardown
  # always run, even when a subclass defines its own #setup without super.
  def before_setup
    super
    @__rh_real_redis = Sidekiq.method(:redis)
    fake = FakeRedis.new
    Sidekiq.define_singleton_method(:redis) { |&blk| blk.call(fake) }
  end

  def after_teardown
    Sidekiq.define_singleton_method(:redis, @__rh_real_redis) if @__rh_real_redis
    super
  end
end
