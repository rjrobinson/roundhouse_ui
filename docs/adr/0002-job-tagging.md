# 0002. Job tagging: read-time resolver with filterable vocabulary

- Status: Accepted
- Date: 2026-07-30

## Problem
Hosts want jobs tagged by some dimension of their own — owning squad, tenant,
product area — and want to see and **filter by** those tags in Roundhouse
(badges on retry/dead/scheduled rows, "show me Growth's failures", errors
grouped by owner). The prior art (Trainual's `SidekiqMiddleware::OwnerTrace`)
is a Sidekiq server middleware that reads an `OWNER` constant off the worker
class and writes a Datadog span tag. That mechanism cannot serve this UI: it is
write-only (the tag goes out to APM, nothing reads it back), it only fires
while a job is *running* (the views we want tagged — retries, dead, scheduled —
show jobs that aren't), and Solid Queue has no middleware chain at all.

## Constraints
- **Backend-neutral.** Must work identically on Sidekiq and Solid Queue
  (ADR 0001); anything middleware-shaped is Sidekiq-only and born dead on SQ.
- **Zero enqueue changes, retroactive.** Tags must appear for jobs already
  sitting in the sets, without touching payloads or client middleware.
- **Must never break a page.** A host-supplied resolver that raises cannot take
  down Retries; same contract as `DurationCollector` ("must never break a job").
- **Bounded cost.** `ErrorGroups` scans up to 1,000 entries per pass and
  `browse`/`bulk_apply` call the matcher per scanned entry — per-entry host
  callbacks multiply fast.
- **No new leak path.** Tag values render in the UI; they must compose with
  `redact_args` rather than bypass it (the #20 concern about positional args).
- ActiveJob-on-Sidekiq stores the real class in `item["wrapped"]`; `item["class"]`
  is the adapter's `JobWrapper`. A class-keyed convention must unwrap or it
  silently no-ops for that whole host segment.

## Options
1. **Read-time resolver** — a host-configured callable resolves tags from the
   job's class/payload when the UI renders. No storage, no middleware, both
   backends, retroactive. Cannot tag jobs whose class no longer exists, keeps
   no history, and doesn't push to APM.
2. **Port the middleware** (Trainual-style server middleware, generalized).
   Gives APM parity, but Sidekiq-only, perform-time-only — the retry/dead/
   scheduled views stay untagged, which is where tags matter most.
3. **Enqueue-time client middleware** baking tags into the payload. Survives
   class renames and allows runtime-state tags, but requires enqueue changes,
   is not retroactive, and needs per-backend client hooks.
4. **Do nothing** — hosts keep hand-rolling APM-side tagging; the UI stays
   undimensioned.

## Decision
**Option 1.** One config seam in the existing house style (a callable, like
`actor_resolver`):

```ruby
RoundhouseUi.job_tags = ->(klass:, item:) { { squad: :growth } }  # Hash or nil
```

- **Unwrapping:** `klass:` passed to the resolver is always the real job class —
  `item["wrapped"] || item["class"]` — so ActiveJob-on-Sidekiq hosts work.
- **Convention shipped, override available:** `Tags.from_constant(:OWNER, as: :squad)`
  builds the resolver for the class-constant convention (Trainual's case is one
  line); any custom lambda overrides it entirely.
- **Cost model, explicit:** by default the resolver is treated as a pure
  function of the class — memoized per class per request, called with
  `item: nil` so an args-reading resolver in the wrong mode fails
  deterministically (rescued → no tags) instead of poisoning the cache with
  first-job-wins values. `RoundhouseUi.job_tags_per_job = true` opts into
  per-job resolution (full `item`, no caching, host pays the per-entry cost).
- **Normalization + redaction:** resolver output is normalized to string
  keys/values and passed through `Redaction.apply`, so existing `redact_args`
  patterns mask tag values by key with no new code. (Key-based only — a tag
  *named* `squad` whose *value* leaks data is not masked; value-level filtering
  remains #20's separate issue.)
- **Failure contract:** everything rescued; failures log a warning and resolve
  to no tags.
- **Filterable vocabulary — convention plus override.** Filtering (`?tag=`,
  applied *identically* in `browse` and `bulk_apply` — no see-N-act-on-M split)
  needs a known set of keys/values for the filter UI. Convention: discover the
  vocabulary from tags resolved during the scan the page already performs
  (zero config, shows what exists). Override: `RoundhouseUi.tag_filters =
  { "squad" => %w[core training growth platform ops ai] }` (values may be
  arrays or callables) declares it authoritatively — stable dropdowns, and
  filtering by an undeclared key matches nothing (fail-closed).
- **Matching is post-redaction:** filters compare against displayed values, so
  a redacted tag matches only its mask — the filter cannot be used as an
  oracle to probe redacted values.

Rollout: (1) `Tags` primitive, no UI; (2) badges on retry/dead/scheduled rows +
job detail; (3) tag annotation on error groups — resolved per *group* at render
(a class-derived tag is constant within a `klass|error` fingerprint), so no
fingerprint change and no per-entry cost; (4) structured `?tag=` filter.

## Risks / Consequences
- **Free-text search stays tag-blind** (deliberate): substring search entering
  `bulk_apply`'s match set would silently widen destructive bulk actions; the
  structured param is the only tag filter, and it is consistent across view
  and bulk.
- Per-job mode makes a 1,000-entry scan cost 1,000 host calls; the flag makes
  that a conscious choice, but a slow resolver is still a slow page.
- Tags resolve from *current* code: a renamed/deleted job class loses its tags
  (accepted — Option 3 is the fix if it ever matters).
- No history/aggregation ("failures per squad this week") — would need a
  collector à la `DurationCollector`, out of scope here.
- APM parity (replacing `owner_trace.rb`) is out of scope; if built later it
  should consume the same resolver, not grow a second convention.
- Pre-existing, surfaced here: `entry_matches?` searches the *wrapper* class
  name for ActiveJob-on-Sidekiq hosts. Same root cause as our unwrapping;
  fixing it is separate work.

## Revisit when
- Someone needs **per-job tags in group fingerprints** (group-by-tenant) — that
  is the fingerprint change deliberately avoided in rollout step 3.
- A **write path** is requested (APM tagging parity) — build it on the same
  resolver.
- Hosts routinely write expensive resolvers — consider a TTL cache above the
  per-request memo.
