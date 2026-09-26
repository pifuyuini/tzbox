import Foundation
#if canImport(XCTest)
import XCTest
#else
import TZBoxTestSupport
#endif
@testable import TZBoxCore

final class NativeLauncherTests: XCTestCase {
    @MainActor
    func testInvalidZoneFailsBeforeAttemptingLaunch() async {
        let launcher = NativeLauncher()
        let entry = AppEntry(name: "Fixture", applicationURL: URL(fileURLWithPath: "/not-an-application"), backend: .native)
        do {
            try await launcher.launch(entry: entry, timeZoneID: "Invalid/Timezone")
            XCTFail("Invalid time zones must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("IANA"))
        }
        XCTAssertTrue(launcher.sessions.isEmpty)
        XCTAssertFalse(launcher.hasRunningApplications)
    }

    @MainActor
    func testChromeBackendCannotBypassDedicatedController() async {
        let launcher = NativeLauncher()
        let entry = AppEntry(name: "Chrome", applicationURL: URL(fileURLWithPath: "/not-an-application"), backend: .chrome)
        do {
            try await launcher.launch(entry: entry, timeZoneID: "Asia/Tokyo")
            XCTFail("Chrome must use the dedicated controller")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("专用"))
        }
        XCTAssertFalse(launcher.isRunning(entry.id))
    }
}

final class NativePersistenceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["TZBOX_TEST_ROOT"] else {
            throw TZBoxError("TZBOX_TEST_ROOT must name a marked repository test directory.")
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tmp = repository.appendingPathComponent("tmp", isDirectory: true).resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        guard root.path.hasPrefix(tmp.path + "/"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex-tmp").path) else {
            throw TZBoxError("Test directory is outside repository tmp or lacks its marker.")
        }
        directory = root.appendingPathComponent("native-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("Created by NativePersistenceTests\n".utf8).write(to: directory.appendingPathComponent(".codex-tmp"))
    }

    override func tearDownWithError() throws {
        guard let directory else { return }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tmp = repository.appendingPathComponent("tmp", isDirectory: true).resolvingSymlinksInPath()
        guard directory.resolvingSymlinksInPath().path.hasPrefix(tmp.path + "/"),
              try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(".codex-tmp").path) else {
            throw TZBoxError("Refusing to remove an unmarked or relocated test directory.")
        }
        let knownNames: Set<String> = [".codex-tmp", "native-sessions.json"]
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
        for url in contents {
            guard knownNames.contains(url.lastPathComponent),
                  try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw TZBoxError("Unknown test artifact retained: \(url.lastPathComponent)")
            }
        }
        try FileManager.default.removeItem(at: directory)
    }

    func testSessionRecordRoundTripPreservesLaunchIdentity() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000.125)
        let record = NativeSessionRecord(
            session: NativeSession(entryID: UUID(), processID: 123, timeZoneID: "Asia/Tokyo", applicationVersion: "1.0", startedAt: start),
            bundleURL: URL(fileURLWithPath: "/Synthetic.app"), launchDate: start
        )
        let restored = try JSONDecoder().decode(NativeSessionRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored.session.entryID, record.session.entryID)
        XCTAssertEqual(restored.session.processID, record.session.processID)
        XCTAssertEqual(restored.session.timeZoneID, "Asia/Tokyo")
        XCTAssertEqual(restored.session.startedAt, start)
        XCTAssertTrue(restored.session.isRunning)
        XCTAssertEqual(restored.bundleURL, record.bundleURL)
        XCTAssertEqual(restored.launchDate, start)
    }

    @MainActor
    func testMissingArchiveStartsCleanWithoutWriting() async throws {
        let launcher = NativeLauncher(sessionDirectory: directory)
        XCTAssertNil(launcher.persistenceError)
        XCTAssertFalse(launcher.hasRunningApplications)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("native-sessions.json").path))
    }

    @MainActor
    func testCorruptedArchiveIsPreservedDuringRefresh() async throws {
        let archive = directory.appendingPathComponent("native-sessions.json")
        let original = Data("{corrupted-session".utf8)
        try original.write(to: archive)
        let launcher = NativeLauncher(sessionDirectory: directory)
        XCTAssertNotNil(launcher.persistenceError)
        launcher.refresh()
        XCTAssertEqual(try Data(contentsOf: archive), original)
        XCTAssertNotNil(launcher.persistenceError)
    }

    @MainActor
    func testTerminatedSessionIsRemovedFromArchive() async throws {
        let archive = directory.appendingPathComponent("native-sessions.json")
        let stale = NativeSessionRecord(
            session: NativeSession(entryID: UUID(), processID: -1, timeZoneID: "Asia/Tokyo", applicationVersion: "1.0"),
            bundleURL: URL(fileURLWithPath: "/Synthetic.app"), launchDate: Date(timeIntervalSince1970: 1)
        )
        try JSONEncoder().encode([stale]).write(to: archive)
        let launcher = NativeLauncher(sessionDirectory: directory)
        XCTAssertTrue(launcher.sessions.isEmpty)
        XCTAssertFalse(launcher.hasRunningApplications)
        XCTAssertNil(launcher.persistenceError)
        let saved = try JSONDecoder().decode([NativeSessionRecord].self, from: Data(contentsOf: archive))
        XCTAssertTrue(saved.isEmpty)
    }
}
