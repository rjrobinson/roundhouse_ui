# 0001. Backend port for multi-queue support (Sidekiq + Solid Queue)

- Status: Accepted
- Date: 2026-07-01

## Problem
Roundhouse reads Sidekiq's Redis-backed data model directly (`Sidekiq::*` calls
scattered through controllers and views). We want it to also drive **Solid Queue**
(SQL-backed, the Rails 8 default) with Roundhouse's existing high-signal UI — which
we consider better than Mission Control – Jobs — without a frontend rewrite or new
build tooling.

## Constraints
- **No new frontend dependency, no build step.** Roundhouse must stay Hotwire +
  vendored `turbo.js`, inline nonce'd CSS, and a strict self-contained CSP so it
  remains a drop-in mountable engine. Any abstraction is server-side only.
- Sidekiq (Redis API) and Solid Queue (Active Record / SQL) **share no substrate** —
  every data read differs.
- Existing Sidekiq behavior must stay **provably identical** through the refactor
  (all 101 tests green) and keep the committed **Sidekiq >= 6.5** floor.
- A new backend must be a **soft/optional dependency** (loaded only when present),
  the same pattern used for `sidekiq-failures`.
- Solid Queue commonly runs on a **separate database**; the adapter must handle
  multi-DB connections and SQL reads on large tables (pagination/indexes).

## Options
1. **Full backend port** — define a `Backend` interface the UI talks to; ship a
   `SidekiqBackend` (refactor of today's code) and later a `SolidQueueBackend`.
   Clean and multi-backend; larger up-front refactor.
2. **Do nothing** — stay Sidekiq-only, point Solid Queue users at Mission Control.
   Least work; forfeits the broader Rails audience and a UI we think is better.
3. **Partial abstraction** — port only the read views; leave Sidekiq-only features
   unported. Less work; leaves a murky two-tier feature story in the codebase.

## Decision
**Option 1, executed incrementally.** Step 1: extract the `Backend` port and a
`SidekiqBackend` as a **pure refactor** — zero behavior change, all tests still
green. Step 2: add `SolidQueueBackend` as **purely additive**, `solid_queue`
soft-required. Chosen because the port decouples the UI from Sidekiq (valuable on
its own, even without Solid Queue), the incremental split de-risks it (Sidekiq
can't break in Step 1; Step 2 can't touch Sidekiq), and it keeps the no-build /
self-contained frontend constraint fully intact since it's a backend-only change.
The UX edge over Mission Control is the reason to invest at all.

## Risks / Consequences
- Solid Queue has **no lifetime processed/failed counters** (Sidekiq::Stats gives
  these for free). Those metrics degrade or must be derived on SQ — consistent with
  the earlier "lean on Datadog, don't build a metrics store" call.
- **Feature parity will be uneven** (consciously accepted): Sidekiq-only concepts
  (capsules, cancellation middleware, Redis snapshots, the pause fetcher) don't map
  to SQ; SQ's native queue pause is actually simpler there.
- Multi-DB and SQL scan cost give SQ a **different performance profile** than Redis;
  reads need pagination and lean on indexed columns.
- Step 1 is up-front refactor cost with **no user-visible change**.

## Revisit when
- **End of Step 2**, or sooner if the abstraction leaks: if more than ~20% of
  controller actions need backend-specific conditionals to work, the `Backend`
  interface is wrong — redesign it or fall back to Option 3 (partial).
- A **third backend** is requested (e.g. GoodJob): use it to confirm the port
  generalizes rather than encoding two-backend assumptions.
