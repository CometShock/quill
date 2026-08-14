# Update Checker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tray-menu update checker: "upstream moved — rebase" for the fork maintainer, "branch updated since last check" for people running the branch. Advisory only; nothing downloads.

**Architecture:** An `UpdateChecker` actor makes up to three unauthenticated GitHub API GETs (repo info → parent, compare → behind_by, branch → head SHA), derives an `UpdateStatus` via pure static functions (fixture-tested), and persists a last-seen SHA in Application Support. `AppController` runs one background check at launch when opted in; a "Check for updates" menu item always works; results render as a clickable status line in the tray menu (transcription-status pattern) that opens the GitHub compare page.

**Tech Stack:** Swift 6 / SPM, Foundation URLSession + JSONSerialization, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-13-update-checker-design.md`

## Global Constraints

- Swift 6 strict concurrency; macOS 15 floor; no new dependencies; single binary.
- Default **off**: `update_check.enabled` defaults to `false`; with it off, quill makes no network requests except when the user clicks "Check for updates".
- Any network/parse failure → `.failed`; manual checks render it, background checks stay silent. No retries.
- The checker can never affect recording or transcription — no shared state with either.
- Built-from identity constants: `UpdateChecker.defaultRepo = "CometShock/quill"`, `defaultBranch = "live-transcript"` (upstream retarget = editing these two strings).
- State file: `~/Library/Application Support/quill/update-check.json` — never in `~/.config/quill`.
- Style: `///` why-comments; lowercase user-facing status strings; menu items Sentence case ("Check for updates").
- Branch: `live-transcript`; commit per task with the message given.

## GitHub API facts (for the implementer)

- `GET https://api.github.com/repos/{owner}/{repo}` → JSON with optional `"parent": {"full_name": "...", "default_branch": "..."}` (absent for non-forks). Requires a `User-Agent` header.
- `GET .../repos/{parent}/compare/{base}...{headOwner}:{branch}` → `"behind_by": Int` (commits base has that head lacks) and `"html_url"` (the human compare page).
- `GET .../repos/{owner}/{repo}/branches/{branch}` → `"commit": {"sha": "..."}`.
- Unauthenticated rate limit is 60 req/hr/IP — three requests per check is fine.

## File Structure

```
Sources/quill/
  Update/UpdateChecker.swift        Task 1 (status enum, parsing, derivation, state) + Task 2 (actor/network)
  Config.swift                      Task 2 — modify: update_check accessors
  UI/MenuBarController.swift        Task 3 — modify: status line + menu item
  UI/ConfigTrayView.swift           Task 3 — modify: opt-in toggle
  Quill.swift                       Task 3 — modify: AppController wiring
README.md                           Task 3 — modify
Tests/quillTests/
  UpdateCheckerTests.swift          Task 1
```

---

### Task 1: Status derivation, response parsing, last-seen state

Everything unit-testable, no network. One file holds the whole update
feature (it's small); the actor half arrives in Task 2.

**Files:**
- Create: `Sources/quill/Update/UpdateChecker.swift`
- Test: `Tests/quillTests/UpdateCheckerTests.swift`

**Interfaces:**
- Consumes: Foundation only.
- Produces (Tasks 2, 3 depend on):
  - `enum UpdateStatus: Equatable, Sendable { case upToDate; case rebaseNeeded(count: Int, compareURL: URL); case branchMoved(compareURL: URL); case failed }`
  - `actor UpdateChecker` (shell for now) with `static let defaultRepo = "CometShock/quill"`, `static let defaultBranch = "live-transcript"`, and nested `struct RepoInfo: Equatable { let parentFullName: String?; let parentDefaultBranch: String? }`
  - `static func parseRepo(_ data: Data) -> RepoInfo?` (nil = unparseable; parsed-but-no-parent = RepoInfo with nils)
  - `static func parseCompare(_ data: Data) -> (behindBy: Int, htmlURL: URL)?`
  - `static func parseBranchHead(_ data: Data) -> String?`
  - `static func derive(behindBy: Int?, rebaseURL: URL?, headSHA: String, lastSeenSHA: String?, movedURL: URL) -> UpdateStatus`
  - `enum UpdateCheckState { static func loadLastSeen(from: URL) -> String?; static func saveLastSeen(_ sha: String, to: URL) }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/quillTests/UpdateCheckerTests.swift`:

```swift
import Foundation
import Testing

@testable import quill

struct UpdateCheckerTests {
    // MARK: fixtures (shape-matched to the GitHub API)

    static let forkRepoJSON = Data("""
        {"full_name": "CometShock/quill",
         "parent": {"full_name": "digimata/quill", "default_branch": "master"}}
        """.utf8)
    static let nonForkRepoJSON = Data(#"{"full_name": "digimata/quill"}"#.utf8)
    static let compareBehindJSON = Data("""
        {"behind_by": 3, "ahead_by": 27,
         "html_url": "https://github.com/digimata/quill/compare/master...CometShock:live-transcript"}
        """.utf8)
    static let compareCurrentJSON = Data("""
        {"behind_by": 0, "ahead_by": 27,
         "html_url": "https://github.com/digimata/quill/compare/master...CometShock:live-transcript"}
        """.utf8)
    static let branchJSON = Data("""
        {"name": "live-transcript", "commit": {"sha": "246e9a8ce123e5159b43045e2e8c2f73f3ea8fdb"}}
        """.utf8)

    let movedURL = URL(string: "https://github.com/CometShock/quill/compare/abc...live-transcript")!
    let rebaseURL = URL(string: "https://github.com/digimata/quill/compare/master...CometShock:live-transcript")!

    // MARK: parsing

    @Test func parsesForkParent() {
        let info = UpdateChecker.parseRepo(Self.forkRepoJSON)
        #expect(info == UpdateChecker.RepoInfo(
            parentFullName: "digimata/quill", parentDefaultBranch: "master"))
    }

    @Test func parsesNonForkAsParentless() {
        let info = UpdateChecker.parseRepo(Self.nonForkRepoJSON)
        #expect(info == UpdateChecker.RepoInfo(parentFullName: nil, parentDefaultBranch: nil))
    }

    @Test func garbageRepoJSONIsNil() {
        #expect(UpdateChecker.parseRepo(Data("not json".utf8)) == nil)
    }

    @Test func parsesCompareBehindAndURL() {
        let parsed = UpdateChecker.parseCompare(Self.compareBehindJSON)
        #expect(parsed?.behindBy == 3)
        #expect(parsed?.htmlURL == rebaseURL)
    }

    @Test func parsesBranchHeadSHA() {
        #expect(UpdateChecker.parseBranchHead(Self.branchJSON)
            == "246e9a8ce123e5159b43045e2e8c2f73f3ea8fdb")
    }

    // MARK: derivation

    @Test func behindUpstreamWinsOverBranchMove() {
        let status = UpdateChecker.derive(
            behindBy: 3, rebaseURL: rebaseURL,
            headSHA: "new", lastSeenSHA: "old", movedURL: movedURL)
        #expect(status == .rebaseNeeded(count: 3, compareURL: rebaseURL))
    }

    @Test func branchMoveReportedWhenRebaseClean() {
        let status = UpdateChecker.derive(
            behindBy: 0, rebaseURL: rebaseURL,
            headSHA: "new", lastSeenSHA: "old", movedURL: movedURL)
        #expect(status == .branchMoved(compareURL: movedURL))
    }

    @Test func firstRunRecordsSilently() {
        let status = UpdateChecker.derive(
            behindBy: 0, rebaseURL: rebaseURL,
            headSHA: "new", lastSeenSHA: nil, movedURL: movedURL)
        #expect(status == .upToDate)
    }

    @Test func nonForkSkipsRebaseSignal() {
        let status = UpdateChecker.derive(
            behindBy: nil, rebaseURL: nil,
            headSHA: "same", lastSeenSHA: "same", movedURL: movedURL)
        #expect(status == .upToDate)
    }

    // MARK: last-seen state

    @Test func lastSeenRoundTripsAndCreatesDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-update-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("nested/update-check.json")
        #expect(UpdateCheckState.loadLastSeen(from: file) == nil)
        UpdateCheckState.saveLastSeen("abc123", to: file)
        #expect(UpdateCheckState.loadLastSeen(from: file) == "abc123")
    }

    @Test func corruptStateFileReadsAsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-update-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("update-check.json")
        try Data("{broken".utf8).write(to: file)
        #expect(UpdateCheckState.loadLastSeen(from: file) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UpdateCheckerTests 2>&1 | tail -10`
Expected: compile FAILURE — `UpdateChecker`, `UpdateStatus`, `UpdateCheckState` not defined.

- [ ] **Step 3: Implement**

Create `Sources/quill/Update/UpdateChecker.swift`:

```swift
import Foundation

/// What the update check found. Advisory only — the UI renders it as a
/// clickable status line; nothing is downloaded or modified.
enum UpdateStatus: Equatable, Sendable {
    case upToDate
    /// The upstream (fork parent) default branch has commits this branch
    /// lacks — the maintainer should rebase/merge.
    case rebaseNeeded(count: Int, compareURL: URL)
    /// The built-from branch head moved since this machine last checked —
    /// an update is available for people running the branch.
    case branchMoved(compareURL: URL)
    case failed
}

/// Checks GitHub for the two signals above. Pure parsing/derivation lives
/// in static funcs (fixture-tested, no network); the actor half performs
/// the requests. Compares branch state on GitHub rather than embedding a
/// build commit — no build-system changes, at the cost of "since last
/// check" rather than "since your build" semantics for the update signal.
actor UpdateChecker {
    /// Built-from identity. Upstreaming this feature = retargeting these
    /// two strings (and users can override via the update_check config).
    static let defaultRepo = "CometShock/quill"
    static let defaultBranch = "live-transcript"

    struct RepoInfo: Equatable {
        let parentFullName: String?
        let parentDefaultBranch: String?
    }

    /// nil = response unparseable; a parsed non-fork yields nil fields
    /// (the rebase signal is skipped, not failed).
    static func parseRepo(_ data: Data) -> RepoInfo? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let parent = json["parent"] as? [String: Any]
        return RepoInfo(
            parentFullName: parent?["full_name"] as? String,
            parentDefaultBranch: parent?["default_branch"] as? String
        )
    }

    static func parseCompare(_ data: Data) -> (behindBy: Int, htmlURL: URL)? {
        guard
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let behind = json["behind_by"] as? Int,
            let urlString = json["html_url"] as? String,
            let url = URL(string: urlString)
        else { return nil }
        return (behind, url)
    }

    static func parseBranchHead(_ data: Data) -> String? {
        guard
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let commit = json["commit"] as? [String: Any],
            let sha = commit["sha"] as? String
        else { return nil }
        return sha
    }

    /// Precedence: rebase beats branch-move (the maintainer's signal is
    /// the actionable one; one status line). First run (no lastSeen)
    /// records silently rather than announcing a "move" it can't date.
    static func derive(
        behindBy: Int?, rebaseURL: URL?,
        headSHA: String, lastSeenSHA: String?, movedURL: URL
    ) -> UpdateStatus {
        if let behindBy, behindBy > 0, let rebaseURL {
            return .rebaseNeeded(count: behindBy, compareURL: rebaseURL)
        }
        if let lastSeenSHA, lastSeenSHA != headSHA {
            return .branchMoved(compareURL: movedURL)
        }
        return .upToDate
    }
}

/// Last-seen branch head, persisted as a tiny JSON file in Application
/// Support (cache, not user config — it never belongs in ~/.config/quill).
/// All failures degrade to first-run behavior: record, don't notify.
enum UpdateCheckState {
    static func loadLastSeen(from url: URL) -> String? {
        guard
            let data = try? Data(contentsOf: url),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return json["last_seen_sha"] as? String
    }

    static func saveLastSeen(_ sha: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? JSONSerialization.data(
            withJSONObject: ["last_seen_sha": sha], options: [.sortedKeys]
        ) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UpdateCheckerTests 2>&1 | tail -10` then full `swift test 2>&1 | tail -5`
Expected: 12 new tests pass; full suite passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/quill/Update/UpdateChecker.swift Tests/quillTests/UpdateCheckerTests.swift
git commit -m "feat: update-check status derivation, parsing, and last-seen state"
```

---

### Task 2: Network check + Config accessors

**Files:**
- Modify: `Sources/quill/Update/UpdateChecker.swift`
- Modify: `Sources/quill/Config.swift`

**Interfaces:**
- Consumes: Task 1's statics.
- Produces (Task 3 depends on):
  - `UpdateChecker.init(repo: String, branch: String)` and `func check() async -> UpdateStatus`
  - `Config.updateCheckEnabled() -> Bool` (default false), `Config.updateCheckRepo() -> String`, `Config.updateCheckBranch() -> String`.

- [ ] **Step 1: Add the actor's stored state and check()**

In `Sources/quill/Update/UpdateChecker.swift`, inside `actor UpdateChecker`, add after the static parse/derive block:

```swift
    private let repo: String
    private let branch: String
    private let stateFile: URL

    init(repo: String, branch: String) {
        self.repo = repo
        self.branch = branch
        stateFile = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("quill/update-check.json")
    }

    enum FetchError: Error {
        case badResponse
    }

    /// One full check: branch head (always), parent + compare (forks
    /// only). Every failure collapses to .failed — an update checker must
    /// never be louder than its news. Records the seen head on success so
    /// the next check compares against it.
    func check() async -> UpdateStatus {
        do {
            guard
                let headSHA = Self.parseBranchHead(
                    try await get("https://api.github.com/repos/\(repo)/branches/\(branch)"))
            else { return .failed }

            guard let info = Self.parseRepo(
                try await get("https://api.github.com/repos/\(repo)"))
            else { return .failed }

            var behindBy: Int?
            var rebaseURL: URL?
            if let parent = info.parentFullName, let parentBranch = info.parentDefaultBranch {
                let owner = repo.split(separator: "/").first.map(String.init) ?? repo
                guard let compare = Self.parseCompare(
                    try await get(
                        "https://api.github.com/repos/\(parent)/compare/\(parentBranch)...\(owner):\(branch)"
                    ))
                else { return .failed }
                behindBy = compare.behindBy
                rebaseURL = compare.htmlURL
            }

            let lastSeen = UpdateCheckState.loadLastSeen(from: stateFile)
            UpdateCheckState.saveLastSeen(headSHA, to: stateFile)
            let movedURL = URL(
                string: "https://github.com/\(repo)/compare/\(lastSeen ?? headSHA)...\(branch)")!
            return Self.derive(
                behindBy: behindBy, rebaseURL: rebaseURL,
                headSHA: headSHA, lastSeenSHA: lastSeen, movedURL: movedURL
            )
        } catch {
            return .failed
        }
    }

    /// GitHub requires a User-Agent; anything non-200 (404, rate limit)
    /// is a plain failure — no retries, next check is next launch/click.
    private func get(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw FetchError.badResponse }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("quill-update-check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FetchError.badResponse
        }
        return data
    }
```

- [ ] **Step 2: Config accessors**

In `Sources/quill/Config.swift`, extend the doc-comment example JSON's top-level object with:

```
///       "update_check": { "enabled": false, "repo": "CometShock/quill", "branch": "live-transcript" },
```

Add after the `liveTranscript()` private helper:

```swift
    /// Whether quill checks GitHub for updates once at launch. Default off
    /// — with this false, quill makes no network requests unless the user
    /// clicks "Check for updates" (the README's nothing-leaves-the-machine
    /// promise stays literal).
    static func updateCheckEnabled() -> Bool {
        updateCheck()?["enabled"] as? Bool ?? false
    }

    static func updateCheckRepo() -> String {
        updateCheck()?["repo"] as? String ?? UpdateChecker.defaultRepo
    }

    static func updateCheckBranch() -> String {
        updateCheck()?["branch"] as? String ?? UpdateChecker.defaultBranch
    }

    private static func updateCheck() -> [String: Any]? {
        load()?["update_check"] as? [String: Any]
    }
```

- [ ] **Step 3: Verify build + full tests + one live manual probe**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: build complete; all tests pass (network code has no unit tests — parsing/derivation were tested in Task 1; the live path is probed next and in Task 3's manual pass).

- [ ] **Step 4: Commit**

```bash
git add Sources/quill/Update/UpdateChecker.swift Sources/quill/Config.swift
git commit -m "feat: update checker network path + update_check config"
```

---

### Task 3: Menu status line, launch wiring, tray toggle, README

**Files:**
- Modify: `Sources/quill/UI/MenuBarController.swift`
- Modify: `Sources/quill/Quill.swift`
- Modify: `Sources/quill/UI/ConfigTrayView.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `UpdateChecker(repo:branch:).check()`, `UpdateStatus`, `Config.updateCheck*()`.
- Produces: `MenuBarController.onCheckForUpdates: (() -> Void)?`, `onUpdateStatusClick: (() -> Void)?`, `func updateUpdateCheck(_ text: String?, clickable: Bool)`.

- [ ] **Step 1: MenuBarController — status line + menu item**

Add a stored property after `private let transcriptionLabel: NSMenuItem`:

```swift
    private let updateLabel: NSMenuItem
```

Add callbacks alongside the others:

```swift
    var onCheckForUpdates: (() -> Void)?
    var onUpdateStatusClick: (() -> Void)?
```

In `init()`, after `menu.addItem(transcriptionLabel)` and before the first separator, add:

```swift
        updateLabel = NSMenuItem(
            title: "", action: #selector(updateStatusClicked), keyEquivalent: ""
        )
        updateLabel.isEnabled = false
        updateLabel.isHidden = true
        menu.addItem(updateLabel)
```

After the `openConfig` item is added, add:

```swift
        let checkUpdates = NSMenuItem(
            title: "Check for updates",
            action: #selector(checkUpdatesClicked),
            keyEquivalent: ""
        )
        menu.addItem(checkUpdates)
```

Extend the target loop to `for item in [updateLabel, toggleItem, liveTranscriptItem, openConfig, checkUpdates, openFolder, quit]`.

Add after `updateTranscription(_:)`:

```swift
    /// Update-check status line, third slot in the status block; nil
    /// hides it. Clickable when there's a compare page to open (rebase /
    /// branch-moved results); plain text otherwise ("up to date").
    func updateUpdateCheck(_ text: String?, clickable: Bool) {
        updateLabel.title = text ?? ""
        updateLabel.isHidden = text == nil
        updateLabel.isEnabled = clickable
    }
```

Add the actions next to the other `@objc` methods:

```swift
    @objc private func checkUpdatesClicked() { onCheckForUpdates?() }
    @objc private func updateStatusClicked() { onUpdateStatusClick?() }
```

- [ ] **Step 2: AppController — checker lifecycle**

In `Sources/quill/Quill.swift`, add stored properties after `private let liveWindow: LiveTranscriptWindowController`:

```swift
    private var updateCompareURL: URL?
```

In `init(root:cliOverride:)`, after the `menuBar.onOpenConfig` line, add:

```swift
        menuBar.onCheckForUpdates = { [weak self] in self?.runUpdateCheck(manual: true) }
        menuBar.onUpdateStatusClick = { [weak self] in
            if let url = self?.updateCompareURL { NSWorkspace.shared.open(url) }
        }
        if Config.updateCheckEnabled() {
            runUpdateCheck(manual: false)
        }
```

(NOTE: `runUpdateCheck` is an instance method used in `init` closures via
`[weak self]` — fine; the direct call on the last line is after all stored
properties are initialized, also fine.)

Add the two methods after `openFolder()`:

```swift
    /// One shot per trigger: build a fresh checker from current config
    /// (so tray edits to repo/branch apply immediately) and render the
    /// result. Background (launch) checks stay quiet unless there's news;
    /// manual clicks always answer, including "up to date" and failure.
    private func runUpdateCheck(manual: Bool) {
        menuBar.updateUpdateCheck(manual ? "checking for updates…" : nil, clickable: false)
        let checker = UpdateChecker(
            repo: Config.updateCheckRepo(), branch: Config.updateCheckBranch()
        )
        Task { [weak self] in
            let status = await checker.check()
            self?.showUpdateStatus(status, manual: manual)
        }
    }

    private func showUpdateStatus(_ status: UpdateStatus, manual: Bool) {
        switch status {
        case .upToDate:
            updateCompareURL = nil
            menuBar.updateUpdateCheck(manual ? "up to date" : nil, clickable: false)
        case .rebaseNeeded(let count, let url):
            updateCompareURL = url
            menuBar.updateUpdateCheck(
                "upstream +\(count) commit\(count == 1 ? "" : "s") — rebase needed",
                clickable: true
            )
        case .branchMoved(let url):
            updateCompareURL = url
            menuBar.updateUpdateCheck("branch updated since last check", clickable: true)
        case .failed:
            updateCompareURL = nil
            menuBar.updateUpdateCheck(
                manual ? "update check failed — offline?" : nil, clickable: false
            )
        }
    }
```

- [ ] **Step 3: ConfigTrayView — opt-in toggle**

In `Sources/quill/UI/ConfigTrayView.swift`, add a state property alongside the others:

```swift
    @State private var updateCheckEnabled = Config.updateCheckEnabled()
```

In `controls`, after the "Mic voice processing" toggle, add:

```swift
            Toggle("Check for updates at launch", isOn: $updateCheckEnabled)
                .onChange(of: updateCheckEnabled) {
                    save(updateCheckEnabled, ["update_check", "enabled"])
                }
```

- [ ] **Step 4: README**

In `README.md`, after the "Live transcript" section, add:

```markdown
## Update check

The menu's **Check for updates** asks GitHub whether the branch this build
came from has moved (and, for fork builds, whether upstream has commits
the branch lacks — time to rebase). Results show as a clickable status
line in the menu that opens the GitHub compare page. Nothing downloads;
it's purely advisory.

Off by default — quill makes no network requests unless you click the
menu item or opt into a once-per-launch check with
`"update_check": { "enabled": true }`.
```

- [ ] **Step 5: Verify build + tests + live manual check**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: build complete, all tests pass.
Live probe (network required): `swift run quill` then click "Check for updates" in the menu — expect "up to date" on first run (records silently) and a second click still "up to date". If offline, expect "update check failed — offline?". Ctrl-C after.

- [ ] **Step 6: Commit**

```bash
git add Sources/quill/UI/MenuBarController.swift Sources/quill/Quill.swift Sources/quill/UI/ConfigTrayView.swift README.md
git commit -m "feat: update check in tray menu — status line, launch opt-in, tray toggle"
```

---

## Self-Review (completed)

- **Spec coverage:** two signals + precedence (T1 derive), parent auto-detect / non-fork skip (T1 parse + T2 check), last-seen persistence in App Support (T1 + T2 path), opt-in launch check default off (T2 config + T3 wiring), manual item always available (T3), clickable status line via compare html_url (T2/T3), quiet failures with manual/background asymmetry (T3 showUpdateStatus), tray toggle (T3), README privacy note (T3), one-constant retarget (T1 constants).
- **Placeholder scan:** clean.
- **Type consistency:** `UpdateStatus` cases, `parseRepo/parseCompare/parseBranchHead/derive` signatures, `UpdateCheckState.loadLastSeen/saveLastSeen`, `UpdateChecker(repo:branch:).check()`, `Config.updateCheckEnabled/Repo/Branch`, `updateUpdateCheck(_:clickable:)` — cross-checked between tasks.
