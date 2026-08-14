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
