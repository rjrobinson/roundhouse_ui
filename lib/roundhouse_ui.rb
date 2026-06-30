require "roundhouse_ui/version"
require "roundhouse_ui/engine"
require "sidekiq/api"
require "roundhouse_ui/pause"
require "roundhouse_ui/fetch"
require "roundhouse_ui/snapshots"
require "roundhouse_ui/observability"
require "roundhouse_ui/audit"
require "roundhouse_ui/redaction"
require "roundhouse_ui/cancellation"
require "roundhouse_ui/cancel_middleware"
require "roundhouse_ui/metrics"

# Brand name is "Roundhouse"; the gem and Ruby namespace are RoundhouseUi
# (matching the published gem name `roundhouse_ui`).
module RoundhouseUi
  class << self
    # When true, destructive actions (purge, retry, delete, …) are disabled.
    # Mount Roundhouse read-only where operators should only observe.
    attr_accessor :read_only

    # Pluggable snapshot storage. Defaults to Redis; assign any object that
    # responds to write(id, blob) / read(id) / delete(id) / ids.
    attr_writer :snapshot_store

    def snapshot_store
      @snapshot_store ||= Snapshots::RedisStore.new
    end

    # Pluggable APM deep-links. Defaults to no links; assign a DatadogAdapter
    # (or your own) to deep-link jobs out to your observability tool.
    attr_writer :observability

    def observability
      @observability ||= Observability::NullAdapter.new
    end

    # How the audit log names the person taking an action. Auth is the host's
    # job, so give Roundhouse a callable that pulls the actor from the request:
    #
    #   RoundhouseUi.actor_resolver = ->(controller) { controller.current_user&.email }
    #
    # Defaults to "anonymous".
    attr_accessor :actor_resolver

    # Opt-in: enqueue brand-new jobs and edit/re-enqueue existing ones from the
    # UI. Off by default — it's a sharp tool (bad edits create unrunnable jobs).
    attr_accessor :allow_job_editing

    # Argument keys (substring, case-insensitive) to mask when displaying jobs.
    # e.g. RoundhouseUi.redact_args = %w[password token secret]. Default: none.
    attr_accessor :redact_args

    # Opt-in: fold failures recorded by the `sidekiq-failures` gem (its `failed`
    # sorted set) into the grouped Errors view. Off by default, and a no-op
    # unless sidekiq-failures is loaded. Jobs with `retry: false` never enter
    # Sidekiq's retry/dead sets, so this is the only way to surface them here.
    attr_accessor :show_sidekiq_failures

    # Seconds between dashboard stat polls. Lower = livelier, but each poll also
    # re-runs the host's auth/routing on the mount, so a busy console can add DB
    # load. Default 5s; raise it if polling shows up in your traces.
    attr_accessor :poll_interval

    # Queue pause/resume is only enforced when RoundhouseUi::Fetch is installed
    # as the server's fetch strategy. If you run reliable fetch (Sidekiq
    # Pro/Enterprise super_fetch) you can't also run our fetcher, so pause can't
    # be enforced — set this to false to hide the pause controls and the
    # "not enforced" warning entirely. Default: true.
    attr_accessor :pause_enabled

    # Configure in an initializer:
    #
    #   RoundhouseUi.configure do |c|
    #     c.read_only = !Rails.env.development?
    #   end
    def configure
      yield self
    end

    # Cooperative cancellation check for long-running jobs:
    #   raise SomeStop if RoundhouseUi.cancelled?(jid)
    def cancelled?(jid)
      Cancellation.cancelled?(jid)
    end
  end

  self.read_only = false
  self.allow_job_editing = false
  self.redact_args = []
  self.show_sidekiq_failures = false
  self.pause_enabled = true
  self.poll_interval = 5
end
