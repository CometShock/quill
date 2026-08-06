import Foundation
import Testing

@testable import quill

/// These tests mutate Config.pathOverride, so they must not run in
/// parallel with each other.
@Suite(.serialized)
struct ConfigWriteTests {
    /// Point Config at a fresh temp file, run the body, restore.
    private func withTempConfig(
        initial: String?, _ body: (URL) throws -> Void
    ) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("config.json")
        if let initial {
            try Data(initial.utf8).write(to: file)
        }
        Config.pathOverride = file
        defer {
            Config.pathOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        try body(file)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test func preservesUnknownKeysOnWrite() throws {
        try withTempConfig(
            initial: #"{"custom_thing": 42, "live_transcript": {"enabled": true, "future_key": "x"}}"#
        ) { file in
            try Config.setValue(false, forKeyPath: ["live_transcript", "enabled"])
            let json = try readJSON(file)
            #expect(json["custom_thing"] as? Int == 42)
            let live = json["live_transcript"] as! [String: Any]
            #expect(live["enabled"] as? Bool == false)
            #expect(live["future_key"] as? String == "x")
        }
    }

    @Test func createsFileAndNestedContainersWhenMissing() throws {
        try withTempConfig(initial: nil) { file in
            try Config.setValue(true, forKeyPath: ["live_transcript", "auto_open"])
            let json = try readJSON(file)
            let live = json["live_transcript"] as! [String: Any]
            #expect(live["auto_open"] as? Bool == true)
            #expect(Config.liveTranscriptAutoOpen() == true)
        }
    }

    @Test func setsTopLevelValue() throws {
        try withTempConfig(initial: "{}") { file in
            try Config.setValue("~/Meetings", forKeyPath: ["recordings_dir"])
            #expect(try readJSON(file)["recordings_dir"] as? String == "~/Meetings")
        }
    }

    @Test func throwsOnMalformedFileWithoutClobbering() throws {
        try withTempConfig(initial: "{not json") { file in
            #expect(throws: ConfigWriteError.self) {
                try Config.setValue(true, forKeyPath: ["live_transcript", "enabled"])
            }
            let raw = try String(contentsOf: file, encoding: .utf8)
            #expect(raw == "{not json")
            #expect(Config.fileIsMalformed())
        }
    }

    @Test func malformedFalseWhenFileMissingOrValid() throws {
        try withTempConfig(initial: nil) { _ in
            #expect(Config.fileIsMalformed() == false)
        }
        try withTempConfig(initial: "{}") { _ in
            #expect(Config.fileIsMalformed() == false)
        }
    }
}
