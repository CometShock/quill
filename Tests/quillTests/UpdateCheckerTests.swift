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
