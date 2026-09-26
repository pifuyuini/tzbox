import Foundation
#if canImport(XCTest)
import XCTest
#else
import TZBoxTestSupport
#endif
@testable import TZBoxCore

@MainActor
final class ChromeControllerTests: XCTestCase {
    /// A self-owned, short-lived executable stands in for a launched browser process.
    /// It does not expose CDP, access any installed app, or require force termination.
    private func fixture(script: String) throws -> URL {
        guard let rootPath = ProcessInfo.processInfo.environment["TZBOX_TEST_ROOT"] else {
            throw TZBoxError("Controller tests require a repository-local TZBOX_TEST_ROOT.")
        }
        let directory = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("chrome-state-\(UUID().uuidString)", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("ChromeControllerTests\n".utf8).write(to: directory.appendingPathComponent(".codex-tmp"))
        let contents = directory.appendingPathComponent("Fixture.app/Contents", isDirectory: true)
        let executable = contents.appendingPathComponent("MacOS/TZBoxChromeFixture")
        try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleExecutable": "TZBoxChromeFixture", "CFBundleIdentifier": "dev.tzbox.fixture.chrome",
            "CFBundleName": "TZBoxChromeFixture", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data(script.utf8).write(to: executable)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return directory
    }

    private func removeFixture(_ directory: URL) throws {
        guard let root = ProcessInfo.processInfo.environment["TZBOX_TEST_ROOT"] else { return }
        let manager = FileManager.default
        let standardized = directory.standardizedFileURL
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        guard standardized.path.hasPrefix(rootURL.path + "/"),
              try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              try String(contentsOf: directory.appendingPathComponent(".codex-tmp"), encoding: .utf8) == "ChromeControllerTests\n"
        else { throw TZBoxError("Fixture cleanup boundary could not be verified.") }
        try manager.removeItem(at: directory)
    }

    func testControlStartupFailureKeepsLiveProcessActiveAndCloseDoesNotPretendSuccess() async throws {
        let directory = try fixture(script: "#!/bin/sh\nexec /bin/sleep 3\n")
        defer { try? removeFixture(directory) }
        let controller = ChromeController(profileDirectory: directory.appendingPathComponent("Profile"), endpointTimeout: 0.05)
        do {
            try await controller.launch(applicationURL: directory.appendingPathComponent("Fixture.app"), timeZoneID: "Asia/Tokyo")
            XCTFail("a fixture without CDP must not launch successfully")
        } catch {}
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.state, .interrupted)
        XCTAssertTrue(controller.processID != nil)
        XCTAssertTrue(controller.report == nil)
        let closed = await controller.close()
        XCTAssertFalse(closed)
        XCTAssertTrue(controller.isActive)
        for _ in 0..<100 {
            if !controller.isActive, controller.state == .stopped { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertTrue(controller.processID == nil)
    }

    func testEarlyProcessExitCannotProduceRunningOrVerifiedState() async throws {
        let directory = try fixture(script: "#!/bin/sh\nexit 0\n")
        defer { try? removeFixture(directory) }
        let controller = ChromeController(profileDirectory: directory.appendingPathComponent("Profile"), endpointTimeout: 1)
        do {
            try await controller.launch(applicationURL: directory.appendingPathComponent("Fixture.app"), timeZoneID: "Asia/Tokyo")
            XCTFail("an exited fixture must not launch successfully")
        } catch {}
        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(controller.state == .failed || controller.state == .stopped)
        XCTAssertTrue(controller.report == nil)
        let closed = await controller.close()
        XCTAssertTrue(closed)
        XCTAssertEqual(controller.state, .stopped)
    }
}
