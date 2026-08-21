require "test_helper"

module RoundhouseUi
  class BusyControllerTest < ActionDispatch::IntegrationTest
    # Real busy entries always expose item — Sidekiq 7+ via Work#job, 6.x via the
    # backend's JobRecord, Solid Queue via its Entry. Keep the fake honest rather
    # than making the helper defensive, which would hide a contract break.
    FakeJobRecord = Struct.new(:klass, :jid, :item)
    FakeWork = Struct.new(:job, :queue, :run_at)

    class FakeWorkSet
      include Enumerable
      def initialize(items) = @items = items # each item: [process_id, tid, work]
      def each(&blk) = @items.each(&blk)
    end

    def test_lists_running_jobs_and_flags_long_running
      work = FakeWork.new(FakeJobRecord.new("SlowImportJob", "j1", {}), "low", Time.now - 120)
      set  = FakeWorkSet.new([ [ "host:4821", "tid-1", work ] ])

      stub_method(Sidekiq::WorkSet, :new, set) do
        get "/roundhouse/busy"

        assert_response :success
        assert_match "SlowImportJob", @response.body
        assert_match "low", @response.body
        assert_match "host:4821", @response.body
        assert_match "2m 0s", @response.body # 120s elapsed, formatted not raw (#31)
        assert_match "⚠", @response.body        # long-running flag
      end
    end

    def teardown = RoundhouseUi.read_only = false

    def test_cancel_marks_the_jid
      with_fake_redis do
        post "/roundhouse/busy/abc123/cancel"
        assert_response :redirect
        assert RoundhouseUi::Cancellation.cancelled?("abc123")
      end
    end

    def test_read_only_blocks_cancel
      RoundhouseUi.read_only = true
      with_fake_redis do
        post "/roundhouse/busy/abc123/cancel"
        assert_response :redirect
        refute RoundhouseUi::Cancellation.cancelled?("abc123")
      end
    end

    def test_empty_when_nothing_running
      stub_method(Sidekiq::WorkSet, :new, FakeWorkSet.new([])) do
        get "/roundhouse/busy"
        assert_response :success
        assert_match "No jobs running", @response.body
      end
    end

    # Sidekiq 6.x yields a plain Hash (no #queue) with an epoch run_at and a JSON
    # payload — calling work.queue/.run_at/.job there raised NoMethodError (500).
    def test_normalizes_sidekiq_6_work_hash
      work = {
        "queue"   => "low",
        "run_at"  => (Time.now - 120).to_i,
        "payload" => %q({"class":"LegacyJob","jid":"j6","args":[]})
      }
      set = FakeWorkSet.new([ [ "host:6500", "tid-9", work ] ])

      stub_method(Sidekiq::WorkSet, :new, set) do
        get "/roundhouse/busy"

        assert_response :success
        assert_match "LegacyJob", @response.body
        assert_match "j6", @response.body
        assert_match "low", @response.body
        assert_match "2m 0s", @response.body # epoch run_at coerced to a Time, then formatted
      end
    end
  end
end
