require "test_helper"

module RoundhouseUi
  # Edit ran `entry.delete` then `backend.push`. On Solid Queue push raises
  # NotImplementedError — a ScriptError, so neither `rescue ArgumentError` nor a
  # bare `rescue` caught it — and the job was gone with no audit record.
  #
  # Solid Queue can no longer reach the route (it lacks :enqueue), so this uses a
  # backend that claims the capability and fails anyway: a Redis blip mid-request,
  # or the next backend someone writes.
  class EditPushBeforeDeleteTest < ActionDispatch::IntegrationTest
    class ExplodingPush
      class Boom < ScriptError; end # not a StandardError, like NotImplementedError

      attr_reader :deleted

      def initialize(entry, &on_push)
        @entry = entry
        @on_push = on_push
        @deleted = false
      end

      def supports?(capability) = %i[retries dead scheduled redis enqueue].include?(capability)
      def set(kind) = kind.to_s == "retry" ? retry_set : FakeSet.new([])
      def retry_set  = FakeSet.new([ @entry ])
      def dead_set   = FakeSet.new([])
      def scheduled_set = FakeSet.new([])
      def push(_payload)
        @on_push.call
        raise(Boom, "cannot enqueue")
      end
    end

    class FakeSet
      include Enumerable
      def initialize(entries) = @entries = entries
      def each(&block) = @entries.each(&block)
      def size = @entries.size
      def find_job(jid) = @entries.find { |e| e.jid == jid }
    end

    class FakeEntry
      attr_reader :jid, :klass, :queue, :args, :item, :deleted
      def initialize(jid)
        @jid, @klass, @queue, @args = jid, "BillingWorker", "default", [ 1 ]
        @item = { "class" => @klass, "args" => @args, "jid" => jid, "queue" => @queue }
        @deleted = false
      end
      def at = nil
      def delete = @deleted = true
    end

    def setup
      @forgery = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = false
      RoundhouseUi.read_only = false
      RoundhouseUi.allow_job_editing = true
      @entry = FakeEntry.new("j1")
      @pushed = false
      RoundhouseUi.backend = ExplodingPush.new(@entry) { @pushed = true }
    end

    def teardown
      ActionController::Base.allow_forgery_protection = @forgery
      RoundhouseUi.backend = nil
      RoundhouseUi.allow_job_editing = false
    end

    def test_a_failed_push_leaves_the_job_where_it_was
      # However the failure surfaces — raised, wrapped, or a 500 — the only thing
      # asserted is that the job is still there.
      begin
        post "/roundhouse/jobs/retry/j1",
             params: { job_class: "BillingWorker", queue: "default", args: "[1]" }
      rescue Exception # rubocop:disable Lint/RescueException
        nil
      end

      # Guards the guard: if the action never ran — job not found, capability
      # refused, read-only — the assertion below would pass for the wrong reason.
      assert @pushed, "push was never attempted, so this proves nothing about the order"

      refute @entry.deleted,
        "the job was deleted before the push that failed, so it is gone and unrecoverable"
    end
  end
end
