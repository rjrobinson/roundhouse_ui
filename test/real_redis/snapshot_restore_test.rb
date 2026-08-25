require_relative "../real_redis_test_case"

module RoundhouseUi
  # "Snapshot → restore — back a queue up before you purge it, and put it back if
  # you were wrong." The safety net under the most destructive button in the UI,
  # and nothing had ever exercised it against a real Redis.
  class RealRedisSnapshotRestoreTest < RealRedisTestCase
    def push(queue, count)
      count.times { |i| Sidekiq::Client.push("class" => "BillingWorker", "queue" => queue, "args" => [ i ]) }
    end

    def test_a_purged_queue_comes_back_whole
      push("billing", 25)
      before = Sidekiq::Queue.new("billing").map(&:value)

      snap = Snapshots.take("billing")
      assert_equal 25, snap[:count]

      Sidekiq::Queue.new("billing").clear
      assert_equal 0, Sidekiq::Queue.new("billing").size, "purge did not empty the queue"

      assert_equal 25, Snapshots.restore(snap[:id])
      assert_equal 25, Sidekiq::Queue.new("billing").size
    end

    def test_the_restored_jobs_are_the_same_jobs_in_the_same_order
      push("billing", 10)
      before = Sidekiq::Queue.new("billing").map(&:value)

      snap = Snapshots.take("billing")
      Sidekiq::Queue.new("billing").clear
      Snapshots.restore(snap[:id])

      after = Sidekiq::Queue.new("billing").map(&:value)
      assert_equal before, after,
        "restored payloads differ from what was backed up — jids, args or order changed"
    end

    def test_a_restored_queue_is_one_sidekiq_will_actually_work
      # Sidekiq::Queue#clear removes the name from the `queues` set as well as
      # deleting the list. A restore that only RPUSHes the payloads back leaves
      # the jobs in a list no worker polls and no page lists — the queue looks
      # empty and the jobs never run, which is worse than not restoring at all.
      push("billing", 5)
      snap = Snapshots.take("billing")
      Sidekiq::Queue.new("billing").clear
      Snapshots.restore(snap[:id])

      assert_includes Sidekiq::Queue.all.map(&:name), "billing",
        "the restored queue is not registered in the `queues` set: its jobs sit in " \
        "a list no worker polls and the Queues page does not list"
    end

    def test_taking_a_snapshot_does_not_disturb_the_queue
      push("billing", 5)
      Snapshots.take("billing")

      assert_equal 5, Sidekiq::Queue.new("billing").size, "take is documented as non-destructive"
    end
  end
end
