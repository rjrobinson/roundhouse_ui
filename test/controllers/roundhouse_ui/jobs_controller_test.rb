require "test_helper"

module RoundhouseUi
  class JobsControllerTest < ActionDispatch::IntegrationTest
    class FakeEntry
      attr_reader :item, :queue, :jid, :deleted
      def initialize(klass:, queue:, args:, jid: "jid1", extra: {})
        @item = { "class" => klass, "args" => args }.merge(extra)
        @queue = queue
        @jid = jid
        @deleted = false
      end
      def delete = @deleted = true
    end

    class FakeSet
      def initialize(map) = @map = map
      def find_job(jid) = @map[jid]
    end

    def setup
      RoundhouseUi.allow_job_editing = true
      RoundhouseUi.read_only = false
    end

    def teardown
      RoundhouseUi.allow_job_editing = false
      RoundhouseUi.read_only = false
    end

    # Capture what gets pushed to Sidekiq without enqueuing for real.
    def capturing_push
      pushed = []
      original = Sidekiq::Client.method(:push)
      Sidekiq::Client.define_singleton_method(:push) { |payload| pushed << payload; "jid123" }
      yield pushed
    ensure
      Sidekiq::Client.define_singleton_method(:push, original)
    end

    def test_create_enqueues_a_job
      capturing_push do |pushed|
        post "/roundhouse/jobs", params: { job_class: "DemoJob", queue: "low", args: '[1, "x"]' }
        assert_response :redirect
        assert_equal 1, pushed.size
        assert_equal "DemoJob", pushed.first["class"]
        assert_equal "low", pushed.first["queue"]
        assert_equal [ 1, "x" ], pushed.first["args"]
      end
    end

    def test_create_rejects_invalid_json
      capturing_push do |pushed|
        post "/roundhouse/jobs", params: { job_class: "DemoJob", args: "not json" }
        assert_response :unprocessable_entity
        assert_empty pushed
      end
    end

    def test_create_rejects_non_array_args
      capturing_push do |pushed|
        post "/roundhouse/jobs", params: { job_class: "DemoJob", args: '{"a":1}' }
        assert_response :unprocessable_entity
        assert_empty pushed
      end
    end

    def test_edit_renders_a_prefilled_form
      entry = FakeEntry.new(klass: "DemoJob", queue: "default", args: [ 7 ])
      stub_method(Sidekiq::DeadSet, :new, FakeSet.new("e1" => entry)) do
        get "/roundhouse/jobs/dead/e1/edit"
        assert_response :success
        assert_match "DemoJob", @response.body
        assert_match "7", @response.body
      end
    end

    def test_update_deletes_original_and_repushes_edited
      entry = FakeEntry.new(klass: "DemoJob", queue: "default", args: [ 0 ])
      stub_method(Sidekiq::DeadSet, :new, FakeSet.new("e1" => entry)) do
        capturing_push do |pushed|
          post "/roundhouse/jobs/dead/e1", params: { args: "[42]", queue: "critical" }
          assert_response :redirect
          assert entry.deleted, "original entry must be deleted"
          assert_equal [ 42 ], pushed.first["args"]
          assert_equal "critical", pushed.first["queue"]
          assert_equal "DemoJob", pushed.first["class"]
        end
      end
    end

    def test_disabled_blocks_create
      RoundhouseUi.allow_job_editing = false
      capturing_push do |pushed|
        post "/roundhouse/jobs", params: { job_class: "DemoJob", args: "[]" }
        assert_response :redirect
        assert_empty pushed, "nothing enqueued when editing is disabled"
      end
    end

    def test_show_inspects_a_job_with_redacted_args
      RoundhouseUi.allow_job_editing = false # show is read-only, works regardless
      RoundhouseUi.redact_args = %w[token]
      entry = FakeEntry.new(klass: "DemoJob", queue: "default", jid: "j1",
                            args: [ { "token" => "sekret", "id" => 5 } ],
                            extra: { "error_class" => "Boom", "error_message" => "kaboom" })
      stub_method(Sidekiq::DeadSet, :new, FakeSet.new("j1" => entry)) do
        get "/roundhouse/jobs/dead/j1"
        assert_response :success
        assert_match "DemoJob", @response.body
        assert_match "«redacted»", @response.body
        refute_match "sekret", @response.body
        assert_match "Boom", @response.body
      end
    ensure
      RoundhouseUi.redact_args = []
    end

    def test_show_collapses_a_long_backtrace_but_keeps_every_line
      RoundhouseUi.allow_job_editing = false
      bt = (1..40).map { |i| "frame #{i}" }
      entry = FakeEntry.new(klass: "DemoJob", queue: "default", jid: "j1", args: [],
                            extra: { "error_class" => "Boom", "error_backtrace" => bt })
      stub_method(Sidekiq::DeadSet, :new, FakeSet.new("j1" => entry)) do
        get "/roundhouse/jobs/dead/j1"
        assert_response :success
        assert_match "40 lines backtrace", @response.body # collapsible disclosure summary
        assert_match "frame 40", @response.body            # full trace — not truncated at 20
      end
    end

    def test_read_only_blocks_create
      RoundhouseUi.read_only = true
      capturing_push do |pushed|
        post "/roundhouse/jobs", params: { job_class: "DemoJob", args: "[]" }
        assert_response :redirect
        assert_empty pushed
      end
    end
  end
end
