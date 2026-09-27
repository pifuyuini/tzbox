import Foundation
#if canImport(XCTest)
import XCTest
#else
import TZBoxTestSupport
#endif
@testable import TZBoxCore

final class SettingsStoreTests: XCTestCase {
    private var directory: URL!
    private var allowedPaths: Set<String> = [".codex-tmp", "settings.json", "Reports"]

    override func setUpWithError() throws {
        guard let root = ProcessInfo.processInfo.environment["TZBOX_TEST_ROOT"] else {
            throw TZBoxError("TZBOX_TEST_ROOT must name the marked task directory inside the repository tmp directory.")
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tmp = repository.appendingPathComponent("tmp", isDirectory: true).resolvingSymlinksInPath()
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath()
        guard rootURL.path.hasPrefix(tmp.path + "/"),
              FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(".codex-tmp").path) else {
            throw TZBoxError("TZBOX_TEST_ROOT is outside the repository tmp directory or lacks its marker.")
        }
        directory = rootURL.appendingPathComponent("settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("Created by SettingsStoreTests\n".utf8)
            .write(to: directory.appendingPathComponent(".codex-tmp"))
    }

    override func tearDownWithError() throws {
        guard let directory else { return }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tmp = repository.appendingPathComponent("tmp", isDirectory: true).resolvingSymlinksInPath()
        guard directory.resolvingSymlinksInPath().path.hasPrefix(tmp.path + "/"),
              try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(".codex-tmp").path) else {
            throw TZBoxError("Refusing to clean an unmarked or relocated test directory.")
        }
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw TZBoxError("Could not inspect the test directory before cleanup.")
        }
        for case let url as URL in entries {
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            guard allowedPaths.contains(relative),
                  try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw TZBoxError("Unknown test artifact retained: \(relative)")
            }
        }
        try FileManager.default.removeItem(at: directory)
    }

    func testMissingSettingsUsesValidDefaultWithoutWriting() throws {
        let settings = try SettingsStore(directory: directory).load()
        XCTAssertTrue(TimeZones.isValid(settings.timeZoneID))
        XCTAssertTrue(settings.applications.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("settings.json").path))
    }

    func testSettingsRoundTripPreservesApplicationsAndZone() throws {
        let entries = [
            AppEntry(name: "测试应用", applicationURL: URL(fileURLWithPath: "/Applications/Example.app"), backend: .native),
            AppEntry(name: "Chrome", applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"), backend: .chrome)
        ]
        let settings = Settings(timeZoneID: "Asia/Kolkata", applications: entries)
        let store = SettingsStore(directory: directory)
        try store.save(settings)
        let loaded = try store.load()
        XCTAssertEqual(loaded.timeZoneID, settings.timeZoneID)
        XCTAssertEqual(loaded.applications.map(\.id), entries.map(\.id))
        XCTAssertEqual(loaded.applications.map(\.applicationURL), entries.map(\.applicationURL))
        XCTAssertTrue(loaded.applications.allSatisfy { $0.backend == .native })
        let saved = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: directory.appendingPathComponent("settings.json")))
        XCTAssertTrue(saved.applications.allSatisfy { $0.backend == .native })
    }

    func testLegacyChromeSettingsMigrateInMemoryWithoutReadingOrChangingProfile() throws {
        let entries = [AppEntry(name: "Chrome", applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"), backend: .chrome)]
        let legacy = Settings(timeZoneID: "Asia/Tokyo", applications: entries)
        let bytes = try JSONEncoder().encode(legacy)
        let settingsURL = directory.appendingPathComponent("settings.json")
        try bytes.write(to: settingsURL)
        let loaded = try SettingsStore(directory: directory).load()
        XCTAssertEqual(loaded.applications.first?.backend, .native)
        XCTAssertEqual(loaded.applications.first?.id, entries[0].id)
        XCTAssertEqual(loaded.applications.first?.applicationURL, entries[0].applicationURL)
        XCTAssertEqual(try Data(contentsOf: settingsURL), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ChromeProfile").path))
    }

    func testExplicitSettingsRecoveryBacksUpExactOriginalBytes() throws {
        let url = directory.appendingPathComponent("settings.json")
        let original = Data("{broken settings".utf8)
        try original.write(to: url)
        let store = SettingsStore(directory: directory)
        let reset = try store.backupAndReset()
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let backups = contents.filter { $0.lastPathComponent.hasPrefix("settings.backup-") }
        for backup in backups { allowedPaths.insert(backup.lastPathComponent) }
        XCTAssertEqual(backups.count, 1)
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try store.load(), reset)
        XCTAssertTrue(reset.applications.isEmpty)
        XCTAssertTrue(TimeZones.isValid(reset.timeZoneID))
    }

    func testCorruptedSettingsThrowAndRemainUnchanged() throws {
        let url = directory.appendingPathComponent("settings.json")
        let bytes = Data("{broken settings".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try SettingsStore(directory: directory).load())
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testInvalidSaveDoesNotReplaceValidSettings() throws {
        let store = SettingsStore(directory: directory)
        let original = Settings(timeZoneID: "Asia/Tokyo")
        try store.save(original)
        XCTAssertThrowsError(try store.save(Settings(timeZoneID: "Invalid/Timezone")))
        XCTAssertEqual(try store.load(), original)
    }

    func testStoredInvalidZoneThrowsWithoutRepairingFile() throws {
        let url = directory.appendingPathComponent("settings.json")
        let bytes = try JSONEncoder().encode(Settings(timeZoneID: "Invalid/Timezone"))
        try bytes.write(to: url)
        XCTAssertThrowsError(try SettingsStore(directory: directory).load())
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testReportPersistsEvidenceAndMissingReportIsNil() throws {
        let store = SettingsStore(directory: directory)
        let id = UUID()
        XCTAssertNil(store.loadReport(for: id))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let report = VerificationReport(
            applicationVersion: "1.2.3", timeZoneID: "Europe/London", checkedAt: date,
            checks: [VerificationCheck(name: "Foundation", outcome: .unverified, detail: "Requires application-specific evidence")]
        )
        allowedPaths.insert("Reports/\(id.uuidString).json")
        try store.saveReport(report, for: id)
        let loaded = try XCTUnwrap(store.loadReport(for: id))
        XCTAssertEqual(loaded.applicationVersion, report.applicationVersion)
        XCTAssertEqual(loaded.timeZoneID, report.timeZoneID)
        XCTAssertEqual(loaded.checkedAt, date)
        XCTAssertEqual(loaded.checks.first?.outcome, .unverified)
        XCTAssertEqual(loaded.checks.first?.detail, report.checks.first?.detail)
        XCTAssertFalse(loaded.passed)
    }
}
