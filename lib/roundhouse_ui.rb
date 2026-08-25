require "roundhouse_ui/version"
require "roundhouse_ui/engine"
require "sidekiq/api"
require "roundhouse_ui/pause"
require "roundhouse_ui/fetch"
require "roundhouse_ui/snapshots"
require "roundhouse_ui/observability"
require "roundhouse_ui/audit"
require "roundhouse_ui/redaction"
require "roundhouse_ui/queue_summary"
require "roundhouse_ui/theme"
require "roundhouse_ui/tags"
require "roundhouse_ui/runbooks"
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
  # A well-formed Ruby constant path, and a sane bound on its length. Used to
  # decide what may reach String#safe_constantize — see .job_class.
  JOB_CLASS_NAME = /\A[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*\z/
  MAX_JOB_CLASS_NAME = 200

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

    # Override any of the UI's colour tokens, as pure CSS custom properties:
    #
    #   RoundhouseUi.theme = { accent: "#FF2BD1", accent_2: "#00E5FF" }
    #   RoundhouseUi.theme = { dark: { bg: "#0A0511" }, light: { bg: "#FFF7FB" } }
    #   RoundhouseUi.theme = RoundhouseUi::Theme::PRESETS[:cyberpunk]
    #
    # Unset tokens keep their shipped values, so a partial theme is fine. Only
    # known tokens are emitted and values are shape-checked — this is
    # interpolated into a stylesheet, where escaping does not make arbitrary
    # input safe. Default: nil.
    attr_accessor :theme

    # Named palettes a viewer can choose between on the Settings page:
    #
    #   RoundhouseUi.themes = { cyberpunk: RoundhouseUi::Theme::PRESETS[:cyberpunk] }
    #
    # `theme` sets the default for everyone; this is the menu each person picks
    # from in their own browser. Default: the shipped presets.
    attr_accessor :themes

    # Where the runbook for a job class lives. A callable, or a Hash keyed by
    # class name:
    #
    #   c.job_runbooks = RoundhouseUi::Runbooks.from_constant(:RUNBOOK)
    #   c.job_runbooks = { "Billing::SyncWorker" => "https://wiki/billing" }
    #
    # Resolved at read time like job_tags, so it applies to jobs already in the
    # sets. Only http(s) URLs are rendered. Default: nil.
    attr_accessor :job_runbooks

    # Set false where an operator should not be able to recolour a production
    # console. Settings then hides palette selection and everyone keeps the
    # host's `theme`. Default: true.
    attr_accessor :allow_theme_selection

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

    # ActiveJob-on-Sidekiq stores the adapter's JobWrapper in item["class"] and
    # the real job class in item["wrapped"]. Solid Queue and raw Sidekiq workers
    # put the real class in klass, and Solid Queue's synthetic item never carries
    # a "wrapped" key — so this is a no-op there and safe to call unconditionally.
    #
    # Reading item["wrapped"] rather than matching on the wrapper's name also
    # covers Sidekiq 7+/8's native Sidekiq::ActiveJob::Wrapper for free.
    #
    # Use for display, search, grouping and APM links, so all four agree on one
    # string. NOT for re-enqueue: a payload pushed back to Redis must keep
    # item["class"] exactly as Sidekiq stored it, or the job is re-created as a
    # raw worker and fails on every attempt.
    def unwrapped_class(klass, item)
      wrapped = item["wrapped"] if item.is_a?(Hash)
      (wrapped || klass)&.to_s
    end

    # When a job was enqueued, as a Time, or nil if the payload does not say.
    #
    # Two formats exist three orders of magnitude apart: Sidekiq 8 writes integer
    # epoch milliseconds, 6.5 and 7 write float epoch seconds. Reading one as the
    # other does not give a slightly wrong time, it gives 1970 or the year 58000.
    def enqueued_at(item)
      raw = item["enqueued_at"] || item["created_at"] if item.is_a?(Hash)
      return nil unless raw

      raw.is_a?(Float) ? Time.at(raw) : Time.at(raw / 1000.0)
    rescue StandardError
      nil
    end

    # Optional allowlist for constant resolution. When set, only these
    # namespaces may be resolved from a job payload:
    #
    #   c.job_class_namespaces = %w[Workers Jobs Billing]
    #
    # This is the only control here that actually restricts what can be loaded.
    # Shape checks do not: Ruby rejects a malformed constant path before it
    # attempts any lookup, so a name like "../../etc/passwd" never reaches
    # autoloading in the first place — only well-formed names do, and those are
    # exactly what a shape check permits.
    #
    # Default nil (no restriction), because most apps do not need it: production
    # Rails sets `eager_load = true`, so every app constant is already loaded and
    # resolving one executes no new file. Set it where the job payload is not
    # fully trusted and you would rather bound the blast radius anyway.
    attr_accessor :job_class_namespaces

    # Resolve a job class name to its Class, for resolvers that read constants
    # off the class (Tags.from_constant, Runbooks.from_constant).
    #
    # The name comes from the job payload — `item["class"]` or `item["wrapped"]`
    # — which is data, not code. Three narrowings, and it is worth being precise
    # about which of them is a security control and which are not:
    #
    #   * The namespace allowlist, when configured, IS one. It runs before the
    #     constant lookup and is the only thing here that decides what may be
    #     resolved.
    #   * The shape and length checks are NOT. They reject names Ruby would
    #     reject anyway, before it attempts a lookup; they are here so the
    #     rejection is explicit and a pathological string is bounded early.
    #   * Requiring a Module back is robustness: a name resolving to an Array
    #     would otherwise be sent `const_defined?`, which it does not answer.
    #
    # What nothing at this layer can do is stop a chosen name for a class that
    # genuinely exists — reading a constant requires loading the class. Hosts who
    # want no constant resolution at all should supply a resolver that does none:
    # a Hash keyed by class name serves both tags and runbooks and never
    # constantizes.
    def job_class(name)
      str = name.to_s
      return nil unless str.length <= MAX_JOB_CLASS_NAME && str.match?(JOB_CLASS_NAME)
      return nil unless namespace_allowed?(str)

      klass = str.safe_constantize
      klass if klass.is_a?(Module)
    end

    def namespace_allowed?(str)
      allowed = job_class_namespaces
      return true if allowed.nil? || Array(allowed).empty?

      Array(allowed).any? { |ns| str == ns.to_s || str.start_with?("#{ns}::") }
    end

    # Durations, in one place. This lived in a view helper, which meant anything
    # in lib/ that wanted to print a duration had to reinvent it — and did, five
    # different ways, including the health signal that reported an hour-old queue
    # as "3616s" (#31). Views reach this through the `duration` helper.
    def duration(seconds)
      return "—" if seconds.nil?

      secs = seconds.to_f.abs
      # Sub-minute keeps a decimal: 0.4s and 12s are a real distinction here.
      return "#{secs.round(1)}s" if secs < 60
      return "#{(secs / 60).floor}m #{(secs % 60).round}s" if secs < 3_600
      return "#{(secs / 3_600).floor}h #{((secs % 3_600) / 60).round}m" if secs < 86_400

      "#{(secs / 86_400).floor}d #{((secs % 86_400) / 3_600).round}h"
    end

    def duration_ms(ms)
      return "—" if ms.nil?
      return "#{ms.to_f.abs.round}ms" if ms.to_f.abs < 1_000

      duration(ms.to_f / 1_000)
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
  self.allow_theme_selection = true
  self.themes = Theme::PRESETS
end
