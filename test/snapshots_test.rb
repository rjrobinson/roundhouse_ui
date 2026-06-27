require "test_helper"

module RoundhouseUi
  class SnapshotsTest < ActiveSupport::TestCase
    FakeJob = Struct.new(:value)

    class FakeQueue
      def initialize(payloads) = @payloads = payloads
      def each
        @payloads.each { |p| yield FakeJob.new(p) }
      end
    end

    def test_take_then_restore_roundtrip
      with_fake_redis do |redis|
        payloads = [ '{"class":"A","jid":"1"}', '{"class":"A","jid":"2"}' ]
        stub_method(Sidekiq::Queue, :new, FakeQueue.new(payloads)) do
          snap = Snapshots.take("low")
          assert_equal "low", snap[:queue]
          assert_equal 2, snap[:count]
          assert_equal 1, Snapshots.all.size

          restored = Snapshots.restore(snap[:id])
          assert_equal 2, restored
          assert_equal 2, redis.call("LLEN", "queue:low"), "jobs re-enqueued onto the original queue"
        end
      end
    end

    def test_delete_removes_the_snapshot
      with_fake_redis do
        stub_method(Sidekiq::Queue, :new, FakeQueue.new([ "{}" ])) do
          snap = Snapshots.take("x")
          assert_equal 1, Snapshots.all.size
          Snapshots.delete(snap[:id])
          assert_empty Snapshots.all
        end
      end
    end

    def test_restore_of_missing_snapshot_is_a_safe_noop
      with_fake_redis do
        assert_equal 0, Snapshots.restore("does-not-exist")
      end
    end
  end
end
