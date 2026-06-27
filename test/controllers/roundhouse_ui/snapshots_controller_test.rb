require "test_helper"

module RoundhouseUi
  class SnapshotsControllerTest < ActionDispatch::IntegrationTest
    FakeJob = Struct.new(:value)
    class FakeQueue
      def initialize(payloads) = @payloads = payloads
      def each
        @payloads.each { |p| yield FakeJob.new(p) }
      end
    end

    def setup = RoundhouseUi.read_only = false
    def teardown = RoundhouseUi.read_only = false

    def test_index_lists_snapshots
      with_fake_redis do
        stub_method(Sidekiq::Queue, :new, FakeQueue.new([ '{"class":"A"}' ])) do
          Snapshots.take("low")
          get "/roundhouse/snapshots"
          assert_response :success
          assert_match "low", @response.body
        end
      end
    end

    def test_restore_re_enqueues_then_index_reflects_it
      with_fake_redis do |redis|
        stub_method(Sidekiq::Queue, :new, FakeQueue.new([ '{"class":"A"}', '{"class":"B"}' ])) do
          snap = Snapshots.take("low")
          post "/roundhouse/snapshots/#{snap[:id]}/restore"
          assert_response :redirect
          assert_equal 2, redis.call("LLEN", "queue:low")
        end
      end
    end

    def test_read_only_blocks_restore
      RoundhouseUi.read_only = true
      with_fake_redis do |redis|
        stub_method(Sidekiq::Queue, :new, FakeQueue.new([ '{"class":"A"}' ])) do
          snap = Snapshots.take("low")
          post "/roundhouse/snapshots/#{snap[:id]}/restore"
          assert_response :redirect
          assert_equal 0, redis.call("LLEN", "queue:low"), "restore must not run in read-only mode"
        end
      end
    end
  end
end
