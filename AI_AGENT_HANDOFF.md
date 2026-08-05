# AI Agent Handoff

Last updated: 2026-08-05
Status: v9.59.0 released and tagged; `main` green; one open PR (#762, an
external contributor's draft) and six open issues, all blocked or awaiting a
maintainer decision
Branch: `main`
Release: https://github.com/nyldn/claude-octopus/releases/tag/v9.59.0
Release squash: `a5d38ee325a823ba2cd4f9ef71f256cae4dec712` (pushed to
`upstream/main`)
Tag target: `v9.59.0` is annotated, resolves to that exact squash commit, and
is pushed; the main-branch Test Suite passed on that commit before tagging

## Start Here

This file is the portable resume point for Claude Code, Codex, and other LLM
harnesses. It is a context packet, not the task tracker.

Read in order:

1. `AGENTS.md` and `RTK.md`
2. `git status --short --branch`
3. the latest commits on the current branch
4. the relevant `bd` issue before editing; if Beads is blocked, read
   `Tracking Blocker` below and do not migrate the database
5. `docs/MODEL-ROUTING-STRATEGY.md`
6. `docs/GPT-5.6-PROMPTING.md`

## Delivered Goal

Opus 5 is the default complex-work owner in Claude Octopus while keeping
Fable 5 as a capability escalation, Codex/GPT-5.6 as an independent peer,
cheaper model tiers, user overrides, and legacy compatibility.

## Decisions

- Opus 5 is the default premium Claude owner, not the only workflow model.
- Fable 5 is an explicit escalation and does not add an independent provider
  organization beside Opus.
- GPT-5.6 Sol is the default Codex peer; Terra and Luna are standard and budget
  tiers.
- Sonnet 5 is the standard Claude seat.
- Explicit user pins and role/phase routes remain higher priority than defaults.
- Claude model allowlists remain a compliance boundary: direct normal and fast
  Opus dispatch validate the final rerouted model and any fallback before
  command serialization.
- Tangle implementation isolation defaults on for orchestrated and direct
  library calls; explicit `OCTOPUS_TANGLE_RUN_WORKTREE=false` is the opt-out.
- Tangle uses one run ID across its branch, delegated tasks, markers, and
  validation artifacts, and resolves caller-relative ignored context before
  changing worktrees.
- Verification-only results fail closed unless all declared evidence members
  are strings and the baseline, reproduction, and implementation flags are
  internally consistent.
- Multi-model fan-out remains mandatory only for commands whose explicit
  contract is council, debate, parallel, or multi-provider research.
- Tests and runtime evidence remain mandatory; redundant prompt-only
  self-verification is removed.
- Release summaries, model defaults, component counts, runtime compatibility,
  and provider counts in the public README surfaces are generated from
  repository sources rather than maintained as duplicated prose.
- `make sync` repairs README drift and `make sync-check` rejects it. Release
  preparation updates the changelog first, then runs the same synchronization.
- Public test-suite counts are derived from the same `test-*.sh` discovery used
  by the smoke, unit, and integration runners.
- Review findings are fixed on the release branch before merge; review comments
  marked addressed are still checked against the actual head rather than
  accepted as evidence.
- `.octo-continue.md` predates this work and is preserved as user-owned state.

## Tracking Blocker

Beads is readable but not writable. The remote-backed database is on schema
v49 with four pending migrations to v53. Repository rules prohibit migrating
without the single designated migrator. No migration was run, so this work
could not be claimed or recorded as a new Beads issue.

## Current Evidence

- Release v9.59.0 is the resume baseline: ten reliability fixes plus literal
  provider-model routing (#734) and three test systems (#749, #752). Tagged on
  the squash commit per `RELEASING.md` step 7, with main verified green first
  per step 9.
- The release notes were rewritten before publication because they described
  three fixes while `main` had gained fifteen more. Every cited PR was verified
  by content, not by label: the batch PRs show CLOSED rather than MERGED
  because #764 squashed them, so a label check reads as though they never
  landed.
- #762 (provider-registry consolidation) is verified, CI-green and Bash 3.2
  clean, but is still the author's **draft**. It was deliberately excluded from
  v9.59.0 and the registry claim was removed from the notes rather than
  shipping a description of a change users would not have. It should lead the
  next release.
- Main went red on the v9.59.0 commit and the tag was held. Root cause was a
  single macOS timing flake, not the release: `integration-heavy` declares
  `needs: [unit-required]`, so a failed unit gate skips it and the `integration`
  gate then fails on `heavy_tests=true` with result `skipped`. One flake, two
  red checks. Both halves fixed in #771.
- The flake was never reproduced locally across eleven runs including three
  under CPU load. What established nondeterminism was a re-run of the identical
  commit going green with no code change.
- #769 fixed a live dispatch break: `grok-exec.sh` and `claude-sdk-exec.sh`
  existed but were absent from `validate_agent_command`'s allowlist, so every
  grok and claude-sdk dispatch aborted before the CLI ran. Third occurrence of
  this pattern after #697 and #705. The fix requires exactly three tokens
  (`env`, `VAR=`, shim), and four injection shapes were confirmed rejected.
- #774 lowered both SessionEnd timeouts to Codex's 3s cap. This reversed an
  earlier judgement made without measurement: `session-end.sh` runs 142 ms
  nominal and 360 ms against a 2.7 MB session file with 6000 errors, 3000
  phases and 300 memory dirs; `workflow-verification.sh` runs 20 ms. Codex
  clamps to 3s regardless, so the declared 15s only ever produced a startup
  warning. `main` now declares zero async hooks and zero over-cap timeouts.
- #775 registered `/octo:whats-new`, which had shipped unregistered since
  2026-07-30 (51 command files, 50 registered). Found by
  `tests/test-command-registration.sh`, one of the 34 files no CI gate runs.
  That is the concrete payoff #752 predicted.
- All 34 unreachable files are triaged: 27 pass and are misplaced (including
  `test-credential-isolation.sh`, which is clean); 1 found the bug above; 1
  (`test-enforcement-pattern.sh`) is stale, demanding an attribution footer
  that **0 of 57** skills carry; 2 are version-named and need reading; 1
  baseline entry points at a deleted file.
- Relocating those 27 is **not** a `git mv`. `tests/` root resolves
  `PROJECT_ROOT` as `$SCRIPT_DIR/..` while `tests/unit/` uses
  `$SCRIPT_DIR/../..`. Demonstrated: a moved test dies on
  `tests/unit/helpers/test-framework.sh: No such file or directory`. A path
  error that resolves rather than errors yields a green test asserting nothing,
  so each move needs verifying by content.
- Three consecutive releases filed identical E2E reports. #717 and #735 are
  closed: their `B2c /octo:model-config` failure no longer reproduces, with no
  root cause identified — treat a recurrence as nondeterministic. The surviving
  `gemini:degraded` is correct behaviour, not a defect:
  `check-providers.sh:30-32` names "gemini exhausted" as a case that should
  report degraded. The stale assertion lives in an external harness. Tracked
  in #772.
- Merged this session with `main` green on every commit: #771 (`ec52a786`),
  #769 (`49e036c0`), #774 (`1b078482`), #775 (`a595a264`), #773 (`be1534b2`).
- `make ci-local` on the #762 branch passed 16 smoke, 201 unit, 7 integration.
  `test-hud-smart-mode.sh` fails in one long-lived local checkout and passes in
  a fresh worktree and in CI; treat it as environmental.
- Auto-merge is disabled at the repository level and merge queues are
  org-only, so under `strict: true` every merge invalidates every other PR.
  Five sequential rebases were needed today. Enabling auto-merge is a one-line
  repository setting and was left for the maintainer.
- `make sync-check` passes with no script mode changes; no stashes; working
  tree clean on `main`.

## Merge Queue

- Merged this session: #771, #769, #774, #775, #773. Earlier in the same cycle:
  #765, #767, and the nine-PR integration batch #764 (#740, #742, #743, #744,
  #747, #757, #758, #759, #761), plus #763, #734, #760, #754, #739, #737, and
  release PR #748 (v9.59.0).
- Open: **#762 only**, an external contributor's draft. Do not convert someone
  else's draft to ready; the author has been asked and told it missed v9.59.0.
- Open issues, none of them available work without a decision or an unblock:
  #768 and the structural half of #750 are blocked on #762; #772 needs a change
  in an external E2E harness; #724 is a phase-handoff contract change needing
  design; #701 is a product-scope call (recommendation given: fold into
  `octopus-ui-ux-design` rather than add a 58th skill); #741 has a scoped plan
  and a ratchet preventing growth.

## Next Action

Merge #762 when its author clears the draft flag, then fix all three #768 items
in one pass. Two decisions belong to the maintainer: enabling repository
auto-merge, and the Beads migration below.
