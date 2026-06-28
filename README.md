<img width="3532" height="1956" alt="CleanShot 2026-06-27 at 21 07 23@2x" src="https://github.com/user-attachments/assets/7c27c997-d8d1-4e8e-b982-94c624ebfa2a" />
# Roundhouse

**A modern, real-time web UI for Sidekiq.**

[![CI](https://github.com/rjrobinson/roundhouse_ui/actions/workflows/ci.yml/badge.svg)](https://github.com/rjrobinson/roundhouse_ui/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/roundhouse_ui)](https://rubygems.org/gems/roundhouse_ui)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.1-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org)
[![Rails](https://img.shields.io/badge/rails-%3E%3D%207.0-D30001?logo=rubyonrails&logoColor=white)](https://rubyonrails.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](MIT-LICENSE)

Roundhouse is a mountable Rails engine that replaces the stock Sidekiq Web UI with a
control plane built for the way you actually operate background jobs: live stats,
searchable sets, grouped errors, safe queue management, job inspection/editing, and
Redis health — all server-rendered with Turbo (no build step), and **no Sidekiq Pro
required**.

> Gem name is `roundhouse_ui`; the brand and mount path are **Roundhouse**.

## Features

- **Live dashboard** — throughput chart + stat cards refresh in place (no reload); polling pauses when the tab is hidden.
- **Search** — find a job across the dead/retry/scheduled sets by class, JID, error, or argument value.
- **Bulk actions** — select many dead jobs and retry/delete them at once (not 25-at-a-time).
- **Grouped errors** — failures fingerprinted by `class + error`, so one bad deploy is a single issue with a count.
- **Queue management** — pause/resume (OSS, see below), purge with an impact count, and **snapshot → restore**.
- **Job inspection & editing** — view a job's full args (with redaction), error, and backtrace; edit & re-enqueue, or enqueue a brand-new job (opt-in).
- **Workers** — process fleet with quiet/stop, threads, queues, and heartbeat.
- **Redis pressure** — memory, ops/sec, and the eviction-policy check that flags silent job loss.
- **Audit log** — every state-changing action recorded and attributable.
- **⌘K command palette**, light/dark themes, read-only mode, and a strict self-contained CSP.

Everything reads through Sidekiq's public API — **no database**.

## Requirements

- Ruby >= 3.1 · Rails >= 7.0 · Sidekiq >= 7.0

## Installation

```ruby
# Gemfile
gem "roundhouse_ui"
```

## Mounting

Roundhouse is auth-agnostic — wrap the mount in whatever your app already uses.

```ruby
# config/routes.rb
authenticate :user, ->(u) { u.admin? } do        # Devise example
  mount RoundhouseUi::Engine => "/roundhouse"
end
```

It ships **no authentication** — always mount it behind yours; it exposes operational
controls over your job system.

## Configuration

```ruby
# config/initializers/roundhouse.rb
RoundhouseUi.configure do |c|
  # Disable every destructive action (purge/retry/delete/edit) server-side.
  c.read_only = !Rails.env.development?

  # Enqueue new jobs and edit/re-enqueue existing ones from the UI (sharp tool — off by default).
  c.allow_job_editing = Rails.env.development?

  # Mask sensitive argument keys (case-insensitive substring) wherever args are displayed.
  c.redact_args = %w[password token secret api_key authorization]

  # Attribute audit entries to the signed-in user instead of "anonymous".
  c.actor_resolver = ->(controller) { controller.current_user&.email }

  # Deep-link jobs out to your APM (see Observability).
  c.observability = RoundhouseUi::Observability::DatadogAdapter.new(service: "my-app")

  # Where queue snapshots are stored (default: Redis). Swap for a file/S3 store.
  # c.snapshot_store = MyS3SnapshotStore.new
end
```

## Pausing queues

Pause/resume is pure OSS. To make a pause actually stop a queue from being worked,
install Roundhouse's fetch strategy in your Sidekiq **server** config:

```ruby
# config/initializers/sidekiq.rb
Sidekiq.configure_server do |config|
  config[:fetch_class] = RoundhouseUi::Fetch
end
```

`RoundhouseUi::Fetch` subclasses `Sidekiq::BasicFetch` and skips paused queues, inheriting
all of Sidekiq's weighting/ordering. Until it's installed, the Queues page records pauses
but **warns that they aren't enforced** (worker and web are separate processes, so
Roundhouse detects whether a fetcher has reported in).

## Cancelling jobs

Cancellation is cooperative — Ruby can't safely kill a running thread. Install the
middleware so a cancelled job is dropped before it runs:

```ruby
# config/initializers/sidekiq.rb
Sidekiq.configure_server do |config|
  config.server_middleware { |chain| chain.add RoundhouseUi::CancelMiddleware }
end
```

The **Busy** page's Cancel button flags a job's JID. A queued/scheduled/retrying job
is then skipped when it would next run; a *currently running* job stops only if it
checks in — e.g. a long loop can `break if RoundhouseUi.cancelled?(jid)`.

## Observability deep-links

The core depends on nothing — it asks the configured adapter for a URL and renders a link
only if one comes back. A Datadog adapter ships in the box; write your own by duck-typing
`job_url` / `queue_url` / `label`:

```ruby
RoundhouseUi.observability = RoundhouseUi::Observability::DatadogAdapter.new(site: "datadoghq.com", service: "my-app")
```

## Snapshots

Back up a queue before purging it (the safety net for clearing a stuck queue), then restore.
Storage is pluggable via `RoundhouseUi.snapshot_store` (default: Redis). For large/stuck
queues use a file or S3 store so the backup doesn't sit in the Redis you're trying to relieve.

## Security

- All destructive actions are CSRF-protected `POST`s — never GET — and gated by `read_only`.
- Roundhouse sets its own strict, self-contained Content-Security-Policy on its responses
  (nonce'd inline script, same-origin only), so it's safe even if the host sets no policy.
- Configure `redact_args` to keep tokens/PII out of the UI; the audit log records who did what.

## Keyboard

`⌘K` (or `Ctrl+K`) opens the command palette — jump to any view or action.

## Development

```bash
bin/rails test      # full suite, ~1s, no Redis required (Sidekiq's API is stubbed)
bundle exec rubocop # lint
```

The dummy app under `test/dummy` mounts the engine at `/roundhouse`; point it at a local
Redis and run `bin/rails server` to click around.

## Roadmap

- Multi-Redis / multi-cluster view (one pane across shards).
- Capsules and cron/periodic views.

## Contributing

Bug reports and pull requests welcome at https://github.com/rjrobinson/roundhouse_ui.

## License

Available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
