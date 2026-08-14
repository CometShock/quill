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
