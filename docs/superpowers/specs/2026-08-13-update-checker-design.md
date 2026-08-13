# Update Checker — Design

**Date:** 2026-08-13
**Status:** Approved
**Goal:** Tray-menu awareness of two git-hosting facts: (1) the upstream
repo has commits this branch lacks — time to rebase; (2) the built-from
branch has moved since this machine last checked — an update is available
for people running the branch. Advisory only: nothing downloads, nothing
self-modifies.

## Decisions made

| Question | Decision |
|---|---|
| What is compared? | Branch state on GitHub, not binary identity — no build-system changes (no embedded commit hash). |
| Rebase signal | GitHub compare API: parent repo's default branch vs built-from branch, `behind_by > 0`. Parent auto-detected via the repo API (`parent.full_name`); non-forks skip this signal. |
| Update signal | Built-from branch head SHA vs a locally persisted last-seen SHA; first check records silently. |
| Background checks | Opt-in (`update_check.enabled`, default **false**), one check per app launch. No timers. Manual menu item always available. |
| Presentation | "Check for updates" menu item + a status line in the tray menu (transcription-status pattern). Clicking the status opens the GitHub compare page. |
| Failures | Quiet: "check failed" status on manual, silent no-op in background. No retries. |
| Built-from identity | Source constants `defaultRepo = "CometShock/quill"`, `defaultBranch = "live-transcript"`, overridable via config. Upstreaming flips the constants to `digimata/quill` / `master`. |
| State file | `~/Library/Application Support/quill/update-check.json` (cache, not user config — stays out of `~/.config/quill`). |

## Architecture

- **`UpdateChecker` (actor, new)** — owns the network calls, comparison
  logic, and last-seen persistence. Emits a result enum the UI renders:
  `upToDate`, `rebaseNeeded(count: Int, compareURL: URL)`,
  `branchMoved(compareURL: URL)`, `failed`. Rebase and update signals can
  both be true; rebase wins the single status line (maintainer's machine),
  with branchMoved shown when rebase is clean.
- **API calls (unauthenticated, api.github.com):**
  1. `GET /repos/{repo}` → `parent.full_name`, `parent.default_branch`
  2. `GET /repos/{parent}/compare/{parentBranch}...{owner}:{branch}` →
     `behind_by`
  3. `GET /repos/{repo}/branches/{branch}` → `commit.sha`
- **`MenuBarController` (touched)** — "Check for updates" item (always
  enabled) + hidden-when-nil status line with a click action (opens
  compare URL via `NSWorkspace`).
- **`AppController` (touched)** — owns the checker; fires the background
  check once at launch when enabled; routes menu clicks.
- **`Config` (touched)** — `update_check` block accessors:
  `updateCheckEnabled()` (default false), `updateCheckRepo()`,
  `updateCheckBranch()` (defaults = the source constants).
- **`ConfigTrayView` (touched)** — one toggle: "Check for updates at
  launch" wired to `update_check.enabled`.

## Privacy

Default-off background behavior preserves the README's "nothing ever
leaves the machine" promise: with the toggle off, quill makes no network
requests except when the user explicitly clicks "Check for updates". The
requests reveal only that some machine asked GitHub about public repo
metadata; no local data is sent.

## Error handling

Any network/parse/rate-limit failure → `.failed`. Manual checks render it
("update check failed — offline?"); background checks stay silent. The
state file failing to read/write degrades to first-run behavior (record,
don't notify). All failures are non-fatal; the checker can never affect
recording or transcription.

## Testing

- Unit (fixtures, no network): compare/branches/repo JSON parsing; signal
  derivation (behind_by 0/N, SHA same/moved/first-run); precedence
  (rebase over branchMoved); last-seen round-trip via a path override.
- Manual: menu click while current (up to date), after a pushed commit
  (branch moved), and offline (quiet failure). The rebase case rides on
  fixtures until upstream actually moves ahead.

## Upstream note

Independent commits, default-off, one-constant retarget. Presentable
upstream standalone or omittable from the PR without touching the
transcript/control-hub work.
