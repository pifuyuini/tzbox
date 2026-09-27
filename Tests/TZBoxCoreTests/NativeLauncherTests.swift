import Foundation
#if canImport(XCTest)
import XCTest
#else
import TZBoxTestSupport
#endif
@testable import TZBoxCore

@MainActor
private final class FakeNativeWorkspace: NativeWorkspaceRuntime {
    var running: [NativeApplicationProcess] = []
    var environments: [[String: String]] = []
    var terminatedIDs: [Int32] = []
    var activatedIDs: [Int32] = []
    var permitsTermination = true
    var exitsAfterTermination = true
    var suspendLaunch = false
    var launchFailure: Error?
    var exitsImmediately = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var nextPID: Int32 = 100

    var runningApplications: [NativeApplicationProcess] { running }

    func describe(_ url: URL) throws -> NativeApplicationDescriptor {
        NativeApplicationDescriptor(url: url.standardizedFileURL, bundleIdentifier: "dev.tzbox.test.app", version: "2.0")
    }

    func launch(_ application: NativeApplicationDescriptor, environment: [String: String]) async throws -> NativeApplicationProcess {
        environments.append(environment)
        if suspendLaunch { await withCheckedContinuation { continuation = $0 } }
        if let launchFailure { throw launchFailure }
        nextPID += 1
        let process = NativeApplicationProcess(processID: nextPID, bundleURL: application.url,
                                               bundleIdentifier: application.bundleIdentifier, launchDate: Date())
        if !exitsImmediately { running.append(process) }
        return process
    }

    func terminate(_ application: NativeApplicationProcess) -> Bool {
        terminatedIDs.append(application.processID)
        guard permitsTermination else { return false }
        if exitsAfterTermination { running.removeAll { $0.processID == application.processID } }
        return true
    }

    func activate(_ application: NativeApplicationProcess) { activatedIDs.append(application.processID) }

    func finishLaunch() {
        suspendLaunch = false
        continuation?.resume()
        continuation = nil
    }

    func waitForLaunch() async throws {
        for _ in 0..<100 {
            if continuation != nil { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw TZBoxError("Fake launcher did not reach its suspension point")
    }

    func addRunning(at url: URL, processID: Int32 = 50) {
        running.append(NativeApplicationProcess(processID: processID, bundleURL: url,
                                               bundleIdentifier: "dev.tzbox.test.app",
                                               launchDate: Date(timeIntervalSince1970: 1_700_000_000)))
    }
}

@MainActor
final class NativeLauncherTests: XCTestCase {
    private func entry(backend: AppBackend = .native) -> AppEntry {
        AppEntry(name: "Fixture", applicationURL: URL(fileURLWithPath: "/Synthetic/Fixture.app"), backend: backend)
    }

    func testInvalidZoneFailsBeforeAttemptingLaunch() async {
        let workspace = FakeNativeWorkspace()
        let launcher = NativeLauncher(workspace: workspace)
        do {
            try await launcher.apply(entry: entry(), timeZoneID: "Invalid/Timezone")
            XCTFail("Invalid time zones must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("IANA"))
        }
        XCTAssertTrue(workspace.environments.isEmpty)
        XCTAssertTrue(launcher.sessions.isEmpty)
    }

    func testLegacyChromeEntryUsesUnifiedLauncherWithOnlyTZ() async throws {
        let workspace = FakeNativeWorkspace()
        let launcher = NativeLauncher(workspace: workspace)
        let entry = entry(backend: .chrome)
        try await launcher.launch(entry: entry, timeZoneID: "Asia/Tokyo")
        XCTAssertEqual(workspace.environments, [["TZ": "Asia/Tokyo"]])
        XCTAssertEqual(launcher.status(for: entry), .runningManaged)
        XCTAssertEqual(launcher.runtime(for: entry).timeZoneID, "Asia/Tokyo")
    }

    func testExistingApplicationIsUnmanagedUntilConfirmedRestart() async throws {
        let workspace = FakeNativeWorkspace()
        let entry = entry()
        workspace.addRunning(at: entry.applicationURL)
        let launcher = NativeLauncher(workspace: workspace)
        launcher.refresh(entries: [entry])
        XCTAssertEqual(launcher.status(for: entry), .runningUnmanaged)
        XCTAssertTrue(launcher.runtime(for: entry).isRunning)
        XCTAssertNil(launcher.runtime(for: entry).timeZoneID)
        XCTAssertFalse(launcher.hasRunningApplications)
        launcher.activate(entry: entry)
        XCTAssertEqual(workspace.activatedIDs, [50])
        try await launcher.apply(entry: entry, timeZoneID: "Asia/Tokyo")
        XCTAssertEqual(workspace.terminatedIDs, [50])
        XCTAssertEqual(workspace.environments.count, 1)
        XCTAssertEqual(launcher.status(for: entry), .runningManaged)
        XCTAssertTrue(launcher.hasRunningApplications)
    }

    func testLaunchCompatibilityEntryPointNeverRestartsExistingApplication() async throws {
        let workspace = FakeNativeWorkspace()
        let entry = entry()
        workspace.addRunning(at: entry.applicationURL)
        let launcher = NativeLauncher(workspace: workspace)
        do {
            try await launcher.launch(entry: entry, timeZoneID: "Asia/Tokyo")
            XCTFail("launch must not restart an existing application implicitly")
        } catch {}
        XCTAssertTrue(workspace.terminatedIDs.isEmpty)
        XCTAssertTrue(workspace.environments.isEmpty)
        XCTAssertEqual(launcher.status(for: entry), .runningUnmanaged)
    }

    func testNewSelectionDoesNotRewriteActualSessionTimeZone() async throws {
        let workspace = FakeNativeWorkspace()
        let launcher = NativeLauncher(workspace: workspace)
        let entry = entry()
        try await launcher.apply(entry: entry, timeZoneID: "Asia/Tokyo")
        let originalPID = launcher.runtime(for: entry).processID
        launcher.refresh(entries: [entry])
        XCTAssertEqual(launcher.runtime(for: entry).timeZoneID, "Asia/Tokyo")
        XCTAssertTrue(launcher.runtime(for: entry).needsReapplication(to: "America/New_York"))
        XCTAssertFalse(launcher.runtime(for: entry).needsReapplication(to: "Asia/Tokyo"))
        try await launcher.apply(entry: entry, timeZoneID: "America/New_York")
        XCTAssertTrue(launcher.runtime(for: entry).processID != originalPID)
        XCTAssertEqual(launcher.runtime(for: entry).timeZoneID, "America/New_York")
    }

    func testRefusedTerminationKeepsActualProcessAndOldTimeZone() async throws {
        let workspace = FakeNativeWorkspace()
        let launcher = NativeLauncher(workspace: workspace)
        let entry = entry()
        try await launcher.apply(entry: entry, timeZoneID: "Asia/Tokyo")
        let originalPID = launcher.runtime(for: entry).processID
        workspace.permitsTermination = false
        do {
            try await launcher.apply(entry: entry, timeZoneID: "America/New_York")
            XCTFail("a refused normal exit must prevent relaunch")
        } catch {}
        XCTAssertEqual(launcher.runtime(for: entry).processID, originalPID)
        XCTAssertEqual(launcher.runtime(for: entry).timeZoneID, "Asia/Tokyo")
        XCTAssertTrue(launcher.runtime(for: entry).isManaged)
        XCTAssertEqual(launcher.status(for: entry), .runningManaged)
        XCTAssertNotNil(launcher.errors[entry.id])
        XCTAssertTrue(launcher.busyEntryIDs.isEmpty)
        XCTAssertEqual(workspace.environments.count, 1)
    }

    func testExitTimeoutNeverForceTerminatesOrStartsAnotherInstance() async throws {
        let workspace = FakeNativeWorkspace()
        let launcher = NativeLauncher(workspace: workspace, terminationTimeout: 0.01)
        let entry = entry()
        try await launcher.apply(entry: entry, timeZoneID: "Asia/Tokyo")
        let originalPID = launcher.runtime(for: entry).processID
        workspace.exitsAfterTermination = false
        do {
            try await launcher.quit(entry: entry)
            XCTFail("a pending save dialog must keep the application running")
        } catch {}
        XCTAssertEqual(launcher.runtime(for: entry).processID, originalPID)
        XCTAssertTrue(launcher.runtime(for: entry).isRunning)
        XCTAssertEqual(workspace.terminatedIDs.count, 1)
        XCTAssertEqual(workspace.environments.count, 1)
        XCTAssertTrue(launcher.busyEntryIDs.isEmpty)
    }

    func testRestoreSystemRemovesTZFromExplicitLaunchEnvironment() async throws {
        let workspace = FakeNativeWorkspace()
        let launcher = NativeLauncher(workspace: workspace, launchEnvironment: [
            "TZ": "Pacific/Honolulu", "TZBOX_FIXTURE": "fixture-only"
        ])
        let entry = entry()
        try await launcher.apply(entry: entry, timeZoneID: "Asia/Tokyo")
        XCTAssertEqual(workspace.environments[0]["TZ"], "Asia/Tokyo")
        try await launcher.restoreSystem(entry: entry)
        XCTAssertNil(workspace.environments[1]["TZ"])
        XCTAssertEqual(workspace.environments[1]["TZBOX_FIXTURE"], "fixture-only")
        XCTAssertTrue(launcher.runtime(for: entry).isRunning)
        XCTAssertFalse(launcher.runtime(for: entry).isManaged)
        XCTAssertNil(launcher.runtime(for: entry).timeZoneID)
        XCTAssertFalse(launcher.hasRunningApplications)
        XCTAssertNil(launcher.sessions[entry.id])
    }

    func testDuplicateOperationOnSameApplicationIsRejectedAcrossEntries() async throws {
        let workspace = FakeNativeWorkspace()
        workspace.suspendLaunch = true
        let launcher = NativeLauncher(workspace: workspace)
        let firstEntry = entry()
        let duplicate = entry()
        let first = Task { try await launcher.apply(entry: firstEntry, timeZoneID: "Asia/Tokyo") }
        try await workspace.waitForLaunch()
        XCTAssertTrue(launcher.busyEntryIDs.contains(firstEntry.id))
        XCTAssertEqual(launcher.status(for: firstEntry), .starting)
        do {
            try await launcher.apply(entry: duplicate, timeZoneID: "America/New_York")
            XCTFail("a second operation on the same application must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("上一项"))
        }
        workspace.finishLaunch()
        try await first.value
        XCTAssertEqual(workspace.environments.count, 1)
        XCTAssertEqual(launcher.runtime(for: firstEntry).timeZoneID, "Asia/Tokyo")
        XCTAssertTrue(launcher.busyEntryIDs.isEmpty)
    }

    func testFailedRelaunchDoesNotKeepPhantomRunningSession() async throws {
        let workspace = FakeNativeWorkspace()
        let launcher = NativeLauncher(workspace: workspace)
        let entry = entry()
        try await launcher.apply(entry: entry, timeZoneID: "Asia/Tokyo")
        workspace.launchFailure = TZBoxError("fixture failed to open")
        do {
            try await launcher.apply(entry: entry, timeZoneID: "America/New_York")
            XCTFail("relaunch failure must be reported")
        } catch {}
        XCTAssertFalse(launcher.runtime(for: entry).isRunning)
        XCTAssertFalse(launcher.hasRunningApplications)
        XCTAssertEqual(launcher.status(for: entry), .failed)
        XCTAssertNotNil(launcher.errors[entry.id])
    }

    func testAnotherCopyWithSameBundleIDIsNeverTerminated() async throws {
        let workspace = FakeNativeWorkspace()
        let entry = entry()
        let otherURL = URL(fileURLWithPath: "/Other/Fixture.app")
        workspace.addRunning(at: otherURL)
        let launcher = NativeLauncher(workspace: workspace)
        launcher.refresh(entries: [entry])
        XCTAssertEqual(launcher.runtime(for: entry).applicationURL, otherURL)
        do {
            try await launcher.apply(entry: entry, timeZoneID: "Asia/Tokyo")
            XCTFail("another application copy must not be terminated implicitly")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("另一份"))
        }
        XCTAssertTrue(workspace.terminatedIDs.isEmpty)
        XCTAssertTrue(workspace.environments.isEmpty)
    }

    func testExcludedPersonalProcessIsUntouchedByApplyRestoreAndQuit() async throws {
        let workspace = FakeNativeWorkspace()
        let entry = entry()
        workspace.addRunning(at: entry.applicationURL, processID: 50)
        let launcher = NativeLauncher(workspace: workspace, excludedProcessIDs: [50])
        launcher.refresh(entries: [entry])
        XCTAssertFalse(launcher.runtime(for: entry).isRunning)

        try await launcher.apply(entry: entry, timeZoneID: "Asia/Tokyo")
        let firstOwnedPID = try XCTUnwrap(launcher.runtime(for: entry).processID)
        XCTAssertTrue(firstOwnedPID != 50)
        XCTAssertTrue(workspace.terminatedIDs.isEmpty)

        try await launcher.apply(entry: entry, timeZoneID: "America/New_York")
        XCTAssertEqual(launcher.runtime(for: entry).timeZoneID, "America/New_York")
        try await launcher.restoreSystem(entry: entry)
        XCTAssertFalse(launcher.runtime(for: entry).isManaged)
        XCTAssertNil(workspace.environments.last?["TZ"])
        try await launcher.quit(entry: entry)

        XCTAssertFalse(launcher.runtime(for: entry).isRunning)
        XCTAssertEqual(workspace.running.map(\.processID), [50])
        XCTAssertFalse(workspace.terminatedIDs.contains(50))
        XCTAssertEqual(workspace.terminatedIDs.count, 3)
        XCTAssertEqual(workspace.environments.count, 3)
    }

    func testQuitStopsWithoutRelaunchAndClearsManagedState() async throws {
        let workspace = FakeNativeWorkspace()
        let launcher = NativeLauncher(workspace: workspace)
        let entry = entry()
        try await launcher.apply(entry: entry, timeZoneID: "Asia/Tokyo")
        try await launcher.quit(entry: entry)
        XCTAssertEqual(workspace.environments.count, 1)
        XCTAssertEqual(launcher.status(for: entry), .stopped)
        XCTAssertFalse(launcher.isRunning(entry.id))
        XCTAssertFalse(launcher.hasRunningApplications)
    }

    func testExternalRelaunchIsObservedButNeverMistakenForManagedSession() async throws {
        let workspace = FakeNativeWorkspace()
        let launcher = NativeLauncher(workspace: workspace)
        let entry = entry()
        try await launcher.apply(entry: entry, timeZoneID: "Asia/Tokyo")
        let old = try XCTUnwrap(workspace.running.first)
        workspace.running = [
            NativeApplicationProcess(processID: old.processID, bundleURL: old.bundleURL, bundleIdentifier: old.bundleIdentifier,
                                     launchDate: old.launchDate?.addingTimeInterval(30))
        ]
        launcher.refresh()
        XCTAssertEqual(launcher.status(for: entry), .runningUnmanaged)
        XCTAssertNil(launcher.runtime(for: entry).timeZoneID)
        XCTAssertFalse(launcher.hasRunningApplications)
    }

    func testIdentityScopedInitialApplyRefusesAnExistingApplication() async throws {
        let workspace = FakeNativeWorkspace()
        let entry = entry()
        workspace.addRunning(at: entry.applicationURL)
        let launcher = NativeLauncher(workspace: workspace)
        do {
            try await launcher.apply(entry: entry, timeZoneID: "Asia/Tokyo", expectedProcess: nil)
            XCTFail("a diagnostic start cannot take ownership of an existing process")
        } catch {}
        XCTAssertTrue(workspace.terminatedIDs.isEmpty)
        XCTAssertTrue(workspace.environments.isEmpty)
        XCTAssertNil(launcher.lastLaunchedProcessIdentity(for: entry))
        XCTAssertEqual(workspace.running.map(\.processID), [50])
    }

    func testIdentityScopedMutationsNeverTouchAReplacementWithReusedPID() async throws {
        let workspace = FakeNativeWorkspace()
        let launcher = NativeLauncher(workspace: workspace)
        let entry = entry()
        try await launcher.apply(entry: entry, timeZoneID: "Asia/Tokyo", expectedProcess: nil)
        let owned = try XCTUnwrap(launcher.lastLaunchedProcessIdentity(for: entry))
        workspace.running = [
            NativeApplicationProcess(processID: owned.processID, bundleURL: owned.bundleURL,
                                     bundleIdentifier: "dev.tzbox.test.app",
                                     launchDate: owned.launchDate.addingTimeInterval(30))
        ]
        // Do not refresh the cached row first: the operation itself must check.
        do {
            try await launcher.quit(entry: entry, expectedProcess: owned)
            XCTFail("cleanup must not close a replacement")
        } catch {}
        do {
            try await launcher.apply(entry: entry, timeZoneID: "Asia/Kolkata", expectedProcess: owned)
            XCTFail("reapply must not restart a replacement")
        } catch {}
        do {
            try await launcher.restoreSystem(entry: entry, expectedProcess: owned)
            XCTFail("restore must not restart a replacement")
        } catch {}
        XCTAssertFalse(launcher.isRunning(owned))
        XCTAssertTrue(launcher.runtime(for: entry).isRunning)
        XCTAssertFalse(launcher.runtime(for: entry).isManaged)
        XCTAssertTrue(workspace.terminatedIDs.isEmpty)
        XCTAssertEqual(workspace.environments.count, 1)
        XCTAssertEqual(workspace.running.count, 1)
    }

    func testIdentityScopedCleanupSelectsOnlyItsOwnProcessAmongSamePathInstances() async throws {
        let workspace = FakeNativeWorkspace()
        let launcher = NativeLauncher(workspace: workspace)
        let entry = entry()
        try await launcher.apply(entry: entry, timeZoneID: "Asia/Tokyo", expectedProcess: nil)
        let owned = try XCTUnwrap(launcher.lastLaunchedProcessIdentity(for: entry))
        workspace.addRunning(at: entry.applicationURL, processID: 900)
        try await launcher.quit(entry: entry, expectedProcess: owned)
        XCTAssertEqual(workspace.terminatedIDs, [owned.processID])
        XCTAssertEqual(workspace.running.map(\.processID), [900])
        XCTAssertEqual(launcher.status(for: entry), .runningUnmanaged)
    }

    func testRestoredSystemProcessKeepsOwnershipIdentityForCleanup() async throws {
        let workspace = FakeNativeWorkspace()
        let launcher = NativeLauncher(workspace: workspace)
        let entry = entry()
        try await launcher.apply(entry: entry, timeZoneID: "Asia/Tokyo", expectedProcess: nil)
        let managed = try XCTUnwrap(launcher.lastLaunchedProcessIdentity(for: entry))
        try await launcher.restoreSystem(entry: entry, expectedProcess: managed)
        let restored = try XCTUnwrap(launcher.lastLaunchedProcessIdentity(for: entry))
        XCTAssertTrue(restored.processID != managed.processID)
        XCTAssertFalse(launcher.runtime(for: entry).isManaged)
        XCTAssertTrue(launcher.isRunning(restored))
        try await launcher.quit(entry: entry, expectedProcess: restored)
        XCTAssertFalse(launcher.isRunning(restored))
        XCTAssertTrue(workspace.running.isEmpty)
    }

    func testImmediateExitCannotProduceManagedState() async throws {
        let workspace = FakeNativeWorkspace()
        workspace.exitsImmediately = true
        let launcher = NativeLauncher(workspace: workspace)
        let entry = entry()
        do {
            try await launcher.apply(entry: entry, timeZoneID: "Asia/Tokyo")
            XCTFail("an exited process cannot be marked managed")
        } catch {}
        XCTAssertFalse(launcher.isRunning(entry.id))
        XCTAssertFalse(launcher.hasRunningApplications)
        XCTAssertEqual(launcher.status(for: entry), .failed)
    }
}

final class NativePersistenceTests: XCTestCase {
    private var directory: URL!
    private var knownNames: Set<String> = [".codex-tmp", "native-sessions.json"]

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
        let launcher = NativeLauncher(sessionDirectory: directory, workspace: FakeNativeWorkspace())
        XCTAssertNil(launcher.persistenceError)
        XCTAssertFalse(launcher.hasRunningApplications)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("native-sessions.json").path))
    }

    @MainActor
    func testCorruptedArchiveIsPreservedDuringRefresh() async throws {
        let archive = directory.appendingPathComponent("native-sessions.json")
        let original = Data("{corrupted-session".utf8)
        try original.write(to: archive)
        let launcher = NativeLauncher(sessionDirectory: directory, workspace: FakeNativeWorkspace())
        XCTAssertNotNil(launcher.persistenceError)
        launcher.refresh()
        XCTAssertEqual(try Data(contentsOf: archive), original)
        XCTAssertNotNil(launcher.persistenceError)
    }

    @MainActor
    func testExplicitRecoveryPreservesOriginalAndRediscoversOnlyUnmanagedApplications() async throws {
        let archive = directory.appendingPathComponent("native-sessions.json")
        let original = Data("{corrupted-session".utf8)
        try original.write(to: archive)
        let workspace = FakeNativeWorkspace()
        let entry = AppEntry(name: "Fixture", applicationURL: URL(fileURLWithPath: "/Synthetic/Fixture.app"))
        workspace.addRunning(at: entry.applicationURL)
        let launcher = NativeLauncher(sessionDirectory: directory, workspace: workspace)
        let backup = try XCTUnwrap(launcher.recoverSessionRecords(entries: [entry]))
        knownNames.insert(backup.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertNil(launcher.persistenceError)
        XCTAssertEqual(launcher.status(for: entry), .runningUnmanaged)
        XCTAssertFalse(launcher.hasRunningApplications)
        XCTAssertNil(launcher.runtime(for: entry).timeZoneID)
        try await launcher.apply(entry: entry, timeZoneID: "Asia/Tokyo")
        XCTAssertEqual(launcher.status(for: entry), .runningManaged)
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    @MainActor
    func testLiveSessionRestoresOnlyWhenPIDPathAndLaunchDateStillMatch() async throws {
        let workspace = FakeNativeWorkspace()
        let entry = AppEntry(name: "Fixture", applicationURL: URL(fileURLWithPath: "/Synthetic/Fixture.app"))
        let first = NativeLauncher(sessionDirectory: directory, workspace: workspace)
        try await first.apply(entry: entry, timeZoneID: "Asia/Tokyo")
        let reopened = NativeLauncher(sessionDirectory: directory, workspace: workspace)
        reopened.refresh(entries: [entry])
        XCTAssertEqual(reopened.status(for: entry), .runningManaged)
        XCTAssertEqual(reopened.runtime(for: entry).timeZoneID, "Asia/Tokyo")
        XCTAssertEqual(reopened.runtime(for: entry).processID, first.runtime(for: entry).processID)
    }

    @MainActor
    func testSaveFailureKeepsLiveSessionAndRetryPersistsIt() async throws {
        let archive = directory.appendingPathComponent("native-sessions.json")
        let workspace = FakeNativeWorkspace()
        let launcher = NativeLauncher(sessionDirectory: directory, workspace: workspace)
        // An owned directory at the file path makes atomic writes fail deterministically.
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
        let entry = AppEntry(name: "Fixture", applicationURL: URL(fileURLWithPath: "/Synthetic/Fixture.app"))
        do {
            try await launcher.apply(entry: entry, timeZoneID: "Asia/Tokyo")
            XCTFail("persistence failure must be reported")
        } catch {}
        XCTAssertTrue(launcher.runtime(for: entry).isRunning)
        XCTAssertTrue(launcher.runtime(for: entry).isManaged)
        XCTAssertEqual(launcher.runtime(for: entry).timeZoneID, "Asia/Tokyo")
        XCTAssertNotNil(launcher.persistenceError)
        XCTAssertTrue(launcher.busyEntryIDs.isEmpty)
        try FileManager.default.removeItem(at: archive)
        try launcher.retryPersistence()
        XCTAssertNil(launcher.persistenceError)
        let saved = try JSONDecoder().decode([NativeSessionRecord].self, from: Data(contentsOf: archive))
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.session.timeZoneID, "Asia/Tokyo")
    }

    @MainActor
    func testTerminatedSessionIsRemovedFromArchive() async throws {
        let archive = directory.appendingPathComponent("native-sessions.json")
        let stale = NativeSessionRecord(
            session: NativeSession(entryID: UUID(), processID: -1, timeZoneID: "Asia/Tokyo", applicationVersion: "1.0"),
            bundleURL: URL(fileURLWithPath: "/Synthetic.app"), launchDate: Date(timeIntervalSince1970: 1)
        )
        try JSONEncoder().encode([stale]).write(to: archive)
        let launcher = NativeLauncher(sessionDirectory: directory, workspace: FakeNativeWorkspace())
        XCTAssertTrue(launcher.sessions.isEmpty)
        XCTAssertFalse(launcher.hasRunningApplications)
        XCTAssertNil(launcher.persistenceError)
        let saved = try JSONDecoder().decode([NativeSessionRecord].self, from: Data(contentsOf: archive))
        XCTAssertTrue(saved.isEmpty)
    }
}
