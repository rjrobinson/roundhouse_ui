require "test_helper"

module RoundhouseUi
  class BusyControllerTest < ActionDispatch::IntegrationTest
    FakeJobRecord = Struct.new(:klass, :jid)
    FakeWork = Struct.new(:job, :queue, :run_at)

    class FakeWorkSet
      include Enumerable
      def initialize(items) = @items = items # each item: [process_id, tid, work]
      def each(&blk) = @items.each(&blk)
    end

    def test_lists_running_jobs_and_flags_long_running
      work = FakeWork.new(FakeJobRecord.new("SlowImportJob", "j1"), "low", Time.now - 120)
      set  = FakeWorkSet.new([ [ "host:4821", "tid-1", work ] ])

      stub_method(Sidekiq::WorkSet, :new, set) do
        get "/roundhouse/busy"

        assert_response :success
        assert_match "SlowImportJob", @response.body
        assert_match "low", @response.body
        assert_match "host:4821", @response.body
        assert_match "minutes", @response.body # 120s elapsed → "2 minutes"
        assert_match "⚠", @response.body        # long-running flag
      end
    end

    def test_empty_when_nothing_running
      stub_method(Sidekiq::WorkSet, :new, FakeWorkSet.new([])) do
        get "/roundhouse/busy"
        assert_response :success
        assert_match "No jobs running", @response.body
      end
    end
  end
end
