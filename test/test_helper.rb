# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
require "rails/test_help"

# Load the Solid Queue schema into the (in-memory) test database so the Solid
# Queue backend adapter can be exercised. Loaded from the installed gem's own
# template, so it always matches the Solid Queue version under test (the CI
# matrix varies that version). The Sidekiq path needs no database.
if defined?(SolidQueue)
  spec = Gem.loaded_specs["solid_queue"]
  schema = File.join(spec.gem_dir, "lib/generators/solid_queue/install/templates/db/queue_schema.rb")
  ActiveRecord::Schema.verbose = false
  load schema
end

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
      # Real Redis deletes a set once its last member is removed, so EXISTS
      # must ignore keys the Hash default-proc materialized as empty arrays.
      when "EXISTS"    then (@strings.key?(args[0]) || @sets.fetch(args[0], []).any?) ? 1 : 0
      when "DEL"       then args.each { |k| @strings.delete(k); @sets.delete(k) }; 1
      when "RPUSH"     then key, *vals = args; @lists[key].concat(vals); @lists[key].size
      when "LPUSH"     then key, *vals = args; vals.each { |v| @lists[key].unshift(v) }; @lists[key].size
      when "LTRIM"     then key, a, b = args; @lists[key] = (@lists[key][a..b] || []); "OK"
      when "LRANGE"    then key, a, b = args; (@lists[key][a..b] || [])
      when "LLEN"      then @lists[args[0]].size
      # Sidekiq's fast-stats path reads the sorted sets it keeps for scheduled,
      # retry and dead. Nothing here exercises their ordering, so cardinality of
      # a plain list is enough — but it has to answer rather than raise, or the
      # poll endpoint cannot be tested at all.
      when "LINDEX"    then @lists[args[0]][args[1].to_i]
      when "SSCAN"     then [ "0", @sets[args[0]].dup ]
      when "HGET"      then nil
      when "HINCRBY", "HINCRBYFLOAT" then 1
      when "ZCARD"     then @lists[args[0]].size
      when "ZRANGE"    then
        key, a, b = args
        out = @lists[key][a.to_i..b.to_i] || []
        args.any? { |x| x.to_s.casecmp?("withscores") } ? out.flat_map { |m| [ m, "0" ] } : out
      when "ZREM"      then key, *ms = args; ms.count { |m| @lists[key].delete(m) }
      when "ZADD"      then key, _score, m = args; @lists[key] |= [ m ]; 1
      when "SCARD"     then @sets[args[0]].size
      when "HGETALL"   then {}
      when "INFO"      then INFO_FIXTURE
      when "EXPIRE"    then 1
      else raise "FakeRedis: unexpected command #{cmd}"
      end
    end

    # Real clients batch commands and return their replies in order; the batched
    # queue read depends on that ordering, so the fake has to model it rather
    # than being bypassed.
    # redis-client exposes every command as a method as well as through `call`,
    # and Sidekiq's API uses both styles. Forwarding keeps the fake honest about
    # that; an unknown command still raises from `call` rather than being
    # silently swallowed here.
    def method_missing(name, *args) = call(name.to_s.upcase, *args)
    def respond_to_missing?(*) = true

    # Sidekiq::Queue.all scans the queue set. Which method it calls depends on the
    # client: Sidekiq 7+ on redis-client uses `sscan`, 6.5 on redis-rb uses
    # `sscan_each` — the same split that makes `conn.call` the only safe
    # signature in lib/. The fake has to answer both or the poll endpoint is
    # only testable on one version.
    def sscan(key, *_args, **_opts) = @sets[key].dup
    def sscan_each(key, **_opts, &blk) = @sets[key].dup.each(&blk)

    def pipelined
      collector = Pipeline.new(self)
      yield collector
      collector.replies
    end

    class Pipeline
      attr_reader :replies
      def initialize(conn)
        @conn = conn
        @replies = []
      end
      def call(cmd, *args) = @replies << @conn.call(cmd, *args)

      # redis-client exposes both styles — `pipe.get(k)` is `pipe.call("GET", k)`
      # — and Sidekiq's fast-stats path uses the method style. Forwarding keeps
      # the fake honest about that rather than only modelling half the client.
      def method_missing(name, *args) = call(name.to_s.upcase, *args)
      def respond_to_missing?(*) = true
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
