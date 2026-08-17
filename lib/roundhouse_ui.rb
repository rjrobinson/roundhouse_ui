require "roundhouse_ui/version"
require "roundhouse_ui/engine"
require "sidekiq/api"
require "roundhouse_ui/pause"
require "roundhouse_ui/fetch"
require "roundhouse_ui/snapshots"
require "roundhouse_ui/observability"
require "roundhouse_ui/audit"
require "roundhouse_ui/redaction"
require "roundhouse_ui/tags"
require "roundhouse_ui/cancellation"
require "roundhouse_ui/cancel_middleware"
require "roundhouse_ui/metrics"
require "roundhouse_ui/error_groups"
require "roundhouse_ui/health"
require "roundhouse_ui/duration_collector"
require "roundhouse_ui/backends/sidekiq"
require "roundhouse_ui/backends/solid_queue"

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

    # Host-defined job tags, resolved at read time (see ADR 0002): a callable
    # given the job's class name and payload, returning a Hash of tags or nil.
    # `klass` is always the real job class (the ActiveJob adapter wrapper is
    # unwrapped first). For the class-constant convention there's a shorthand:
    #
    #   RoundhouseUi.job_tags = RoundhouseUi::Tags.from_constant(:OWNER, as: :squad)
    #   # equivalent to:
    #   RoundhouseUi.job_tags = ->(klass:, item:) {
    #     k = klass.safe_constantize
    #     { squad: k.const_get(:OWNER) } if k&.const_defined?(:OWNER)
    #   }
    #
    # Tag values render in the UI and pass through redact_args masking (by tag
    # key). Must be cheap: by default it's memoized per class per request and
    # called with item: nil. Default: nil (no tags anywhere).
    attr_accessor :job_tags

    # Set true when job_tags derives tags from the payload (args, tenant, …):
    # the resolver is then called once per job with the full item, and nothing
    # is cached — a 1,000-entry scan means 1,000 calls, so keep it fast. Leave
    # false for class-derived tags (OWNER-style constants). Default: false.
    attr_accessor :job_tags_per_job

    # Optional declared filter vocabulary, so tag filter dropdowns are stable
    # instead of discovered from whatever jobs happen to be visible:
    #
    #   RoundhouseUi.tag_filters = { squad: %w[core training growth platform ops ai] }
    #
    # Values (or the whole setting) may be callables for dynamic vocabularies.
    # When set, filtering by an undeclared key matches nothing (fail-closed).
    # Default: nil — the filter UI discovers values from the entries it scans.
    attr_accessor :tag_filters

    # Opt-in: fold failures recorded by the `sidekiq-failures` gem (its `failed`
    # sorted set) into the grouped Errors view. Off by default, and a no-op
    # unless sidekiq-failures is loaded. Jobs with `retry: false` never enter
    # Sidekiq's retry/dead sets, so this is the only way to surface them here.
    attr_accessor :show_sidekiq_failures

    # Opt-in: record per-class job durations (via RoundhouseUi::DurationCollector
    # server middleware) so the Metrics page can show the slowest job classes.
    # Default false; reads/writes a single Redis hash. The flag gates the UI; the
    # collection itself is enabled by installing the middleware.
    attr_accessor :collect_durations

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

    # The queue backend the UI reads through. Defaults to Sidekiq; assign a
    # different adapter (e.g. Solid Queue) to point Roundhouse at another system.
    # See docs/adr/0001-backend-port-multi-queue.md.
    attr_writer :backend

    def backend
      @backend ||= Backends::Sidekiq.new
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
  self.collect_durations = false
  self.job_tags_per_job = false
end
