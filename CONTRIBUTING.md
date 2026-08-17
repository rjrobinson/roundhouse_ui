# Contributing to Roundhouse

Thanks for your interest. Roundhouse is a small, deliberately-scoped gem, and it's
reviewed by one maintainer — so the single most useful thing you can do is **keep
contributions small and agree on the approach before writing code**.

A focused 80-line pull request that does one thing gets reviewed the same week. A
2,000-line pull request that redesigns three subsystems at once may sit for a long
time, or get closed in favour of a smaller version. That isn't about the quality of
the work; it's that large diffs can't be reviewed with any real confidence.

## Before you write code

**Open an issue first** for anything that isn't a trivial fix. Say what problem you're
hitting, how you'd like to solve it, and wait for a reply. This is the cheapest possible
moment to discover that the maintainer wants a different shape, that the feature is
deliberately out of scope, or that half the work already exists.

You can skip the issue for: typo and documentation fixes, an obviously-correct one-line
bug fix with a test, or anything already agreed in an existing issue.

**Larger changes want an ADR.** If your change alters the architecture or adds
host-facing configuration that we'd then have to support forever, write a short
Architecture Decision Record in [`docs/adr/`](docs/adr/) and get agreement on that
*before* implementing. Follow the existing format — Problem, Constraints, Options,
Decision, Risks / Consequences, Revisit when — and see
[0001](docs/adr/0001-backend-port-multi-queue.md) for the level of detail expected.
An ADR is much easier to argue with than 40 files of code.

Changes that should start as an ADR:

- New public configuration on `RoundhouseUi` (each option is API we support indefinitely).
- Anything touching the backend port or the capability system.
- New runtime dependencies, or changes to the gemspec's dependency list.
- Anything that changes the cost of the hot path — per-job Redis calls, per-row work
  in a page render.

## One pull request, one concern

This is the rule that matters most here.

**Do:**

- One logical change per pull request.
- One logical step per commit, each one leaving the suite green.
- Refactors separate from behaviour changes. A pure refactor that provably changes
  nothing is easy to approve; the same refactor tangled with a new feature is not.
- Mechanical churn (renames, formatting, lockfile bumps) in its own commit, ideally its
  own pull request, so it doesn't bury the two lines that actually matter.

**Don't:**

- Don't ship one commit spanning dozens of files. If the commit message needs the word
  "and" more than once, it's more than one commit.
- Don't bundle developer tooling, editor config, CI restructuring, or scaffolding into a
  feature PR. Those are their own PRs, and they're much easier to accept alone.
- Don't include unrelated formatting or "while I was in here" cleanups. Note them in an
  issue instead.
- Don't reformat files you didn't otherwise need to touch.

If a change genuinely can't be small, **split it into a sequence** and say so in the
issue: "PR 1 extracts the seam with no behaviour change, PR 2 adds the new backend on
top." Each PR should stand on its own and be independently revertible. Stacked, reviewable
steps are always welcome — the ask is not "do less work", it's "let it be reviewed in
pieces".

## Local setup

```bash
bundle install
bin/rails test          # full suite
bin/rubocop             # style, matching CI
```

There's no Redis or database to run. The suite uses an in-memory Redis stand-in
(`FakeRedis` in `test/test_helper.rb`) and an in-memory SQLite database for the Solid
Queue backend, so `bin/rails test` works from a clean checkout.

Run a single file or a single test:

```bash
bin/rails test test/pause_test.rb
bin/rails test test/pause_test.rb -n test_pause_unpause_roundtrip
```

To check another Sidekiq version the way CI does (this rewrites `Gemfile.lock` — restore
it before committing):

```bash
SIDEKIQ_VERSION="~> 6.5" bundle install
SIDEKIQ_VERSION="~> 6.5" bin/rails test
```

## What CI checks

Every pull request runs:

| Job | What it proves |
| --- | --- |
| `lint` | `bin/rubocop` is clean (rubocop-rails-omakase) |
| `test (sidekiq ~> 6.5 / ~> 7.0 / ~> 8.0)` | the code resolves and passes on every supported Sidekiq |
| `test (solid_queue ~> 1.0 / ~> 1.5)` | the Solid Queue backend works on each supported version |

All of it must be green. A few things worth knowing before CI tells you the hard way:

- **The Sidekiq floor is `>= 6.5`.** Sidekiq 6.x uses redis-rb and 7+ uses redis-client.
  All Redis access goes through the low-level `conn.call("CMD", ...)` API, whose splat
  signature is identical on both. If you reach for a client-specific method, feature-detect
  it and provide a fallback.
- **Ruby floor is `>= 3.1`, Rails `>= 7.0`.**
- **Pull requests from forks need a maintainer to approve the CI run.** If your checks
  show as pending with nothing running, that's why — it isn't a failure.

## Writing the change

**Tests are not optional.** Every bug fix gets a test that fails before your change and
passes after. Every feature gets tests for the happy path *and* the failure modes.
Minitest, in `test/`, mirroring the structure of `lib/` and `app/`.

Prefer tests that assert the thing you actually care about. If a change is about cost,
assert the cost — `test/cancellation_test.rb` counts Redis round-trips rather than trusting
that the behaviour implies them.

**Match the surrounding code.** This codebase comments densely, and the comments explain
*why* rather than what — the tradeoff taken, the failure mode avoided, the reason a
simpler approach doesn't work. Those comments are the documentation for a lot of the
public API. Please write in that style, and don't delete existing explanation while
moving code around.

**Respect these architectural constraints.** They're deliberate, and a PR that breaks
one will be asked to change:

- **No frontend build step and no new frontend dependency.** Server-rendered Hotwire,
  vendored `turbo.js`, inline nonce'd CSS, strict self-contained CSP. Roundhouse must
  stay a drop-in mountable engine.
- **Read through the backend port.** Don't add `Sidekiq::` or `SolidQueue::` calls to
  controllers or views — go through `RoundhouseUi.backend`. See
  [ADR 0001](docs/adr/0001-backend-port-multi-queue.md).
- **Hide what a backend can't do** via `supports?`, rather than letting a control 500.
- **Optional dependencies stay optional.** Soft-require anything that isn't a hard
  dependency, the way `sidekiq-failures` and `solid_queue` are handled.
- **Never break a job.** Server middleware and collectors rescue their own failures and
  log; a metrics write must never take down a job. The same applies to page renders —
  a host-supplied callable that raises should degrade, not 500.
- **Destructive actions stay honest.** Anything that deletes or mutates jobs must respect
  `read_only`, be audit-logged, and tell the operator what it's about to affect.

## Commits and pull requests

Write commit messages that explain **why**, not just what. Subject in the imperative mood
("Add…", "Fix…", "Use…"), under ~72 characters, then a blank line, then prose that gives
a reviewer the context they'd otherwise have to reconstruct: what was wrong, what you
considered, what tradeoff you accepted. If your change has a subtlety — a staleness
window, a version-specific workaround, an intentional limitation — the commit message and
a code comment are both the right place for it.

In the pull request description, include:

1. What problem this solves, and a link to the issue.
2. What you changed, and anything you deliberately left out.
3. How you verified it — the commands you ran and their output.
4. Any risk or follow-up you're aware of.

Please don't force-push over review feedback. Add commits so the reviewer can see what
changed; the branch gets squashed on merge anyway.

## Documentation and changelog

- **User-facing changes update the `README.md`.** If you add or change configuration,
  update the config example *and* the "When to turn each one on" table.
- **Don't edit `CHANGELOG.md` in a feature PR.** The maintainer writes changelog entries
  at release time, and contributors editing it causes conflicts. Describe the change in
  your PR body instead; that's what the entry gets written from.
- **Don't bump `lib/roundhouse_ui/version.rb`.** Releases are the maintainer's call.

## Releases

For reference, not something contributors do: the maintainer bumps
`lib/roundhouse_ui/version.rb` and `Gemfile.lock`, adds a `CHANGELOG.md` entry
([Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format,
[semver](https://semver.org)), merges that, then publishes a GitHub Release for the tag.
`.github/workflows/release.yml` pushes the gem to RubyGems via trusted publishing.

## Reporting bugs

Include: Roundhouse version, Ruby and Rails versions, the backend (Sidekiq or Solid
Queue) and its version, whether you're on Sidekiq Pro or Enterprise, what you expected,
what happened, and the full stack trace if there is one. A failing test is the most
useful bug report there is.

## Security

Please don't open a public issue for a security vulnerability. Report it privately via
[GitHub security advisories](https://github.com/rjrobinson/roundhouse_ui/security/advisories/new).

## Licence

Contributions are accepted under the [MIT Licence](MIT-LICENSE), the same licence as the
project.
