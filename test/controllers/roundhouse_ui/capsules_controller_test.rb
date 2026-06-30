require "test_helper"

module RoundhouseUi
  class CapsulesControllerTest < ActionDispatch::IntegrationTest
    FakeProcess = Struct.new(:capsules)

    class FakeProcessSet
      include Enumerable
      def initialize(procs) = @procs = procs
      def each(&blk) = @procs.each(&blk)
    end

    def test_aggregates_capsules_across_processes
      p1 = FakeProcess.new({
        "default"  => { "concurrency" => 10, "weights" => { "default" => 1, "mailers" => 2 } },
        "realtime" => { "concurrency" => 5,  "weights" => { "critical" => 10 } }
      })
      p2 = FakeProcess.new({ "default" => { "concurrency" => 10, "weights" => { "default" => 1 } } })

      stub_method(Sidekiq::ProcessSet, :new, FakeProcessSet.new([ p1, p2 ])) do
        get "/roundhouse/capsules"

        assert_response :success
        assert_match "default", @response.body
        assert_match "realtime", @response.body
        assert_match "critical", @response.body
        assert_match "20", @response.body # default capsule concurrency summed across 2 processes
        assert_match "×2", @response.body  # mailers weight
      end
    end

    def test_handles_processes_without_capsules
      stub_method(Sidekiq::ProcessSet, :new, FakeProcessSet.new([ FakeProcess.new(nil) ])) do
        get "/roundhouse/capsules"
        assert_response :success
        assert_match "No capsule data", @response.body
      end
    end

    # Sidekiq 6.x Process has no #capsules method at all (not just nil) — calling
    # it raised NoMethodError and 500'd the page. The respond_to? guard skips it.
    def test_handles_sidekiq_6_process_with_no_capsules_method
      legacy_process = Object.new # responds to nothing, like a 6.x Process here

      stub_method(Sidekiq::ProcessSet, :new, FakeProcessSet.new([ legacy_process ])) do
        get "/roundhouse/capsules"
        assert_response :success
        assert_match "No capsule data", @response.body
      end
    end
  end
end
