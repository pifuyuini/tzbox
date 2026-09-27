import AppKit
import Combine
import Foundation

public struct NativeSession: Identifiable, Codable {
    public var id: UUID { entryID }
    public let entryID: UUID
    public let processID: Int32
    public let timeZoneID: String
    public let applicationVersion: String
    public let startedAt: Date
    public var isRunning: Bool

    public init(entryID: UUID, processID: Int32, timeZoneID: String, applicationVersion: String, startedAt: Date = Date(), isRunning: Bool = true) {
        self.entryID = entryID
        self.processID = processID
        self.timeZoneID = timeZoneID
        self.applicationVersion = applicationVersion
        self.startedAt = startedAt
        self.isRunning = isRunning
    }
}

struct NativeApplicationDescriptor {
    let url: URL
    let bundleIdentifier: String?
    let version: String
}

/// An identity captured from a successful launch, used by diagnostic cleanup to
/// avoid touching an application that later reused the same path or PID.
public struct ApplicationProcessIdentity: Equatable {
    public let processID: Int32
    public let bundleURL: URL
    public let launchDate: Date

    func matches(_ process: NativeApplicationProcess) -> Bool {
        processID == process.processID
            && bundleURL.standardizedFileURL == process.bundleURL.standardizedFileURL
            && launchDate == process.launchDate
    }
}

struct NativeApplicationProcess {
    let processID: Int32
    let bundleURL: URL
    let bundleIdentifier: String?
    let launchDate: Date?

    var identity: ApplicationProcessIdentity? {
        launchDate.map { ApplicationProcessIdentity(processID: processID, bundleURL: bundleURL, launchDate: $0) }
    }

    func matches(_ other: NativeApplicationProcess) -> Bool {
        processID == other.processID
            && bundleURL.standardizedFileURL == other.bundleURL.standardizedFileURL
            && launchDate == other.launchDate
    }
}

/// The runtime seam permits lifecycle tests without touching installed applications.
@MainActor
protocol NativeWorkspaceRuntime: AnyObject {
    var runningApplications: [NativeApplicationProcess] { get }
    func describe(_ url: URL) throws -> NativeApplicationDescriptor
    func launch(_ application: NativeApplicationDescriptor, environment: [String: String]) async throws -> NativeApplicationProcess
    func terminate(_ application: NativeApplicationProcess) -> Bool
    func activate(_ application: NativeApplicationProcess)
}

/// Test drivers may leave pre-existing personal processes outside their scope.
/// Production passes an empty set and uses the same launch/restart implementation.
@MainActor
private final class ExcludingNativeWorkspace: NativeWorkspaceRuntime {
    private let base: NativeWorkspaceRuntime
    private let excludedProcessIDs: Set<Int32>

    init(base: NativeWorkspaceRuntime, excludedProcessIDs: Set<Int32>) {
        self.base = base
        self.excludedProcessIDs = excludedProcessIDs
    }

    var runningApplications: [NativeApplicationProcess] {
        base.runningApplications.filter { !excludedProcessIDs.contains($0.processID) }
    }

    func describe(_ url: URL) throws -> NativeApplicationDescriptor {
        try base.describe(url)
    }

    func launch(_ application: NativeApplicationDescriptor, environment: [String: String]) async throws -> NativeApplicationProcess {
        let process = try await base.launch(application, environment: environment)
        guard !excludedProcessIDs.contains(process.processID) else {
            throw TZBoxError("系统复用了本次操作范围外的应用实例；该进程未被接管或关闭。")
        }
        return process
    }

    func terminate(_ application: NativeApplicationProcess) -> Bool {
        guard !excludedProcessIDs.contains(application.processID) else { return false }
        return base.terminate(application)
    }

    func activate(_ application: NativeApplicationProcess) {
        guard !excludedProcessIDs.contains(application.processID) else { return }
        base.activate(application)
    }
}

@MainActor
private final class SystemNativeWorkspace: NativeWorkspaceRuntime {
    private let launchArguments: [String]

    init(launchArguments: [String] = []) { self.launchArguments = launchArguments }

    var runningApplications: [NativeApplicationProcess] {
        NSWorkspace.shared.runningApplications.compactMap(Self.snapshot)
    }

    func describe(_ url: URL) throws -> NativeApplicationDescriptor {
        let url = url.standardizedFileURL
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url), let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw TZBoxError("请选择包含可执行文件的 macOS .app 应用。")
        }
        return NativeApplicationDescriptor(
            url: url, bundleIdentifier: bundle.bundleIdentifier,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        )
    }

    func launch(_ application: NativeApplicationDescriptor, environment: [String: String]) async throws -> NativeApplicationProcess {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // Pass only this operation's override. Restoring system behavior uses [:],
        // never the TZBox process environment or the previous session's TZ value.
        configuration.environment = environment
        configuration.arguments = launchArguments
        let launched: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: application.url, configuration: configuration) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let application {
                    continuation.resume(returning: application)
                } else {
                    continuation.resume(throwing: TZBoxError("系统未返回已启动的应用。"))
                }
            }
        }
        guard let snapshot = Self.snapshot(launched) else {
            throw TZBoxError("应用启动后立即退出，时区效果未经验证。")
        }
        return snapshot
    }

    func terminate(_ application: NativeApplicationProcess) -> Bool {
        guard let running = NSRunningApplication(processIdentifier: application.processID),
              let current = Self.snapshot(running) else { return true }
        // Revalidate the exact object immediately before the normal quit request;
        // never resolve a replacement by bundle ID or path at this point.
        guard application.matches(current) else { return false }
        return running.terminate()
    }

    func activate(_ application: NativeApplicationProcess) {
        NSRunningApplication(processIdentifier: application.processID)?.activate(options: [.activateAllWindows])
    }

    private static func snapshot(_ application: NSRunningApplication) -> NativeApplicationProcess? {
        guard !application.isTerminated, let url = application.bundleURL else { return nil }
        return NativeApplicationProcess(processID: application.processIdentifier, bundleURL: url.standardizedFileURL,
                                        bundleIdentifier: application.bundleIdentifier, launchDate: application.launchDate)
    }
}

// The launch date distinguishes the original application from a reused process ID.
struct NativeSessionRecord: Codable {
    let session: NativeSession
    let bundleURL: URL
    let launchDate: Date

    func matches(_ application: NativeApplicationProcess) -> Bool {
        session.processID == application.processID
            && application.bundleURL.standardizedFileURL == bundleURL.standardizedFileURL
            && application.launchDate == launchDate
    }
}

@MainActor
public final class NativeLauncher: ObservableObject {
    @Published public private(set) var sessions: [UUID: NativeSession] = [:]
    @Published public private(set) var runtimes: [UUID: ApplicationRuntime] = [:]
    @Published public private(set) var busyEntryIDs: Set<UUID> = []
    @Published public private(set) var errors: [UUID: String] = [:]
    @Published public private(set) var persistenceError: String?

    private let workspace: NativeWorkspaceRuntime
    private let sessionDirectory: URL?
    private let terminationTimeout: TimeInterval
    private let launchEnvironment: [String: String]
    private let notificationCenter: NotificationCenter?
    private var records: [UUID: NativeSessionRecord] = [:]
    private var lastLaunchedProcesses: [UUID: ApplicationProcessIdentity] = [:]
    private var entries: [UUID: AppEntry] = [:]
    private var descriptors: [UUID: NativeApplicationDescriptor] = [:]
    private var operationPhases: [UUID: ProxyStatus] = [:]
    private var restorationFailed = false
    private var needsPersistence = false
    private var persistenceFailureEntries: Set<UUID> = []
    private var terminationObserver: NSObjectProtocol?

    public convenience init(sessionDirectory: URL? = nil, launchArguments: [String] = [],
                            launchEnvironment: [String: String] = [:], excludedProcessIDs: Set<Int32> = []) {
        self.init(sessionDirectory: sessionDirectory, workspace: SystemNativeWorkspace(launchArguments: launchArguments),
                  terminationTimeout: 12, launchEnvironment: launchEnvironment, excludedProcessIDs: excludedProcessIDs)
    }

    init(sessionDirectory: URL? = nil, workspace: NativeWorkspaceRuntime, terminationTimeout: TimeInterval = 12,
         launchEnvironment: [String: String] = [:], excludedProcessIDs: Set<Int32> = []) {
        self.workspace = ExcludingNativeWorkspace(base: workspace, excludedProcessIDs: excludedProcessIDs)
        self.sessionDirectory = sessionDirectory
        self.terminationTimeout = terminationTimeout
        self.launchEnvironment = launchEnvironment
        self.notificationCenter = workspace is SystemNativeWorkspace ? NSWorkspace.shared.notificationCenter : nil
        restoreSessions()
        if let notificationCenter {
            terminationObserver = notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
    }

    deinit {
        if let terminationObserver {
            notificationCenter?.removeObserver(terminationObserver)
        }
    }

    /// Only sessions actually launched with TZ by this tool count as managed.
    public var hasRunningApplications: Bool { sessions.values.contains { $0.isRunning } }

    public func isRunning(_ entryID: UUID) -> Bool {
        runtimes[entryID]?.isRunning == true || sessions[entryID]?.isRunning == true
    }

    public func status(for entry: AppEntry) -> ProxyStatus { runtime(for: entry).status }

    public func runtime(for entry: AppEntry) -> ApplicationRuntime {
        runtimes[entry.id] ?? ApplicationRuntime(entryID: entry.id)
    }

    /// Compatibility entry point for developer probes. It never restarts an app
    /// implicitly; the user-facing apply operation performs the confirmed restart.
    public func launch(entry: AppEntry, timeZoneID: String) async throws {
        try await perform(entry: entry, operation: .launch(timeZoneID))
    }

    /// The caller confirms a normal restart before applying to an existing app.
    public func apply(entry: AppEntry, timeZoneID: String) async throws {
        try await perform(entry: entry, operation: .apply(timeZoneID))
    }

    public func restoreSystem(entry: AppEntry) async throws {
        try await perform(entry: entry, operation: .restoreSystem)
    }

    public func quit(entry: AppEntry) async throws {
        try await perform(entry: entry, operation: .quit)
    }

    /// Diagnostic operations bind the mutation to a previously captured identity.
    /// Passing nil requires the application to be stopped; it never means any PID.
    public func apply(entry: AppEntry, timeZoneID: String, expectedProcess: ApplicationProcessIdentity?) async throws {
        try await perform(entry: entry, operation: .apply(timeZoneID),
                          expectation: expectedProcess.map(ProcessExpectation.identity) ?? .stopped)
    }

    public func restoreSystem(entry: AppEntry, expectedProcess: ApplicationProcessIdentity?) async throws {
        try await perform(entry: entry, operation: .restoreSystem,
                          expectation: expectedProcess.map(ProcessExpectation.identity) ?? .stopped)
    }

    public func quit(entry: AppEntry, expectedProcess: ApplicationProcessIdentity) async throws {
        try await perform(entry: entry, operation: .quit, expectation: .identity(expectedProcess))
    }

    public func lastLaunchedProcessIdentity(for entry: AppEntry) -> ApplicationProcessIdentity? {
        lastLaunchedProcesses[entry.id]
    }

    public func isRunning(_ identity: ApplicationProcessIdentity) -> Bool {
        workspace.runningApplications.contains { identity.matches($0) }
    }

    public func activate(_ entryID: UUID) {
        if let entry = entries[entryID] { activate(entry: entry); return }
        guard let record = records[entryID],
              let process = workspace.runningApplications.first(where: { record.matches($0) }) else { return }
        workspace.activate(process)
    }

    public func activate(entry: AppEntry) {
        let processes = workspace.runningApplications
        if let process = processes.first(where: { $0.bundleURL.standardizedFileURL == entry.applicationURL.standardizedFileURL }) {
            workspace.activate(process)
        }
    }

    public func refresh(entries: [AppEntry]) {
        var updated: [UUID: AppEntry] = [:]
        for entry in entries { updated[entry.id] = entry }
        for id in busyEntryIDs { if let entry = self.entries[id] { updated[id] = entry } }
        self.entries = updated
        refresh()
    }

    public func refresh() {
        let processes = workspace.runningApplications
        for (id, session) in sessions where session.isRunning {
            if records[id].map({ record in processes.contains { record.matches($0) } }) != true {
                sessions[id]?.isRunning = false
                records.removeValue(forKey: id)
                needsPersistence = true
            }
        }
        var updated: [UUID: ApplicationRuntime] = [:]
        for entry in entries.values {
            if let descriptor = try? workspace.describe(entry.applicationURL) { descriptors[entry.id] = descriptor }
            let matches = matchingApplications(for: entry, in: processes)
            let recorded = records[entry.id].flatMap { record in matches.first { record.matches($0) } }
            let process = recorded ?? matches.first
            let managed = recorded != nil && matches.count == 1
            let status: ProxyStatus
            if let phase = operationPhases[entry.id] { status = phase }
            else if process != nil { status = managed ? .runningManaged : .runningUnmanaged }
            else { status = errors[entry.id] == nil ? .stopped : .failed }
            updated[entry.id] = ApplicationRuntime(
                entryID: entry.id, processID: process?.processID,
                timeZoneID: managed ? sessions[entry.id]?.timeZoneID : nil,
                isManaged: managed, isBusy: busyEntryIDs.contains(entry.id), status: status,
                applicationURL: process?.bundleURL, applicationVersion: descriptors[entry.id]?.version,
                instanceCount: matches.count
            )
        }
        runtimes = updated
        if needsPersistence && !restorationFailed {
            do { try persistSessions() } catch { /* The running state remains available; show persistenceError. */ }
        }
    }

    /// Explicit recovery preserves the original archive and observes existing apps
    /// as unmanaged. Scanning a process is never evidence that its TZ was applied.
    @discardableResult
    public func recoverSessionRecords(entries: [AppEntry]) throws -> URL? {
        guard busyEntryIDs.isEmpty else { throw TZBoxError("请等待当前应用操作结束后再恢复运行记录。") }
        let backup = try archiveURL.flatMap { try SettingsRecovery.backupExistingFile(at: $0) }
        sessions.removeAll()
        records.removeAll()
        errors.removeAll()
        persistenceFailureEntries.removeAll()
        restorationFailed = false
        persistenceError = nil
        needsPersistence = true
        refresh(entries: entries)
        try persistSessions()
        return backup
    }

    public func retryPersistence() throws {
        guard !restorationFailed else { throw TZBoxError("原运行记录无法读取，请使用“恢复运行记录”保留原件并重新扫描。") }
        try persistSessions()
    }

    private enum Operation {
        case launch(String), apply(String), restoreSystem, quit

        var timeZoneID: String? {
            switch self {
            case .launch(let zone), .apply(let zone): return zone
            case .restoreSystem, .quit: return nil
            }
        }
    }

    private enum ProcessExpectation {
        case any, stopped
        case identity(ApplicationProcessIdentity)
    }

    private func perform(entry: AppEntry, operation: Operation, expectation: ProcessExpectation = .any) async throws {
        if let zone = operation.timeZoneID, !TimeZones.isValid(zone) {
            throw TZBoxError("无效的 IANA 时区：\(zone)")
        }
        let descriptor: NativeApplicationDescriptor
        if case .quit = operation {
            descriptor = (try? workspace.describe(entry.applicationURL))
                ?? descriptors[entry.id]
                ?? NativeApplicationDescriptor(url: entry.applicationURL.standardizedFileURL, bundleIdentifier: nil, version: "未知")
        } else {
            descriptor = try workspace.describe(entry.applicationURL)
        }
        let busySameApplication = busyEntryIDs.contains { id in
            guard let other = descriptors[id] else { return id == entry.id }
            return other.url == descriptor.url
                || (descriptor.bundleIdentifier != nil && descriptor.bundleIdentifier == other.bundleIdentifier)
        }
        guard !busyEntryIDs.contains(entry.id), !busySameApplication else {
            throw TZBoxError("\(entry.name) 正在处理上一项操作，请稍候。")
        }
        entries[entry.id] = entry
        descriptors[entry.id] = descriptor
        busyEntryIDs.insert(entry.id)
        operationPhases[entry.id] = .starting
        errors.removeValue(forKey: entry.id)
        defer {
            operationPhases.removeValue(forKey: entry.id)
            busyEntryIDs.remove(entry.id)
            refresh()
        }
        do {
            if restorationFailed, operation.timeZoneID != nil {
                throw TZBoxError("运行记录无法读取。请先使用“恢复运行记录”，原文件将保留为备份。")
            }
            refresh()
            let candidates = matchingApplications(for: entry, in: workspace.runningApplications)
            let running: NativeApplicationProcess?
            switch expectation {
            case .any:
                guard candidates.count <= 1 else {
                    throw TZBoxError("\(entry.name) 有多个独立运行实例，请先正常退出其他实例，再重新应用时区。")
                }
                running = candidates.first
            case .stopped:
                guard candidates.isEmpty else {
                    throw TZBoxError("发现已有应用实例；隔离测试不会重启或关闭该实例。")
                }
                running = nil
            case .identity(let expected):
                guard let matching = candidates.first(where: { expected.matches($0) }) else {
                    throw TZBoxError("原进程已退出或身份已变化；未操作其他应用实例。")
                }
                running = matching
            }
            if let running, running.bundleURL.standardizedFileURL != descriptor.url.standardizedFileURL {
                throw TZBoxError("另一份同名应用正在运行：\(running.bundleURL.path)。请添加这份正在运行的应用，或先正常退出它。")
            }
            if case .launch = operation, running != nil {
                throw TZBoxError("\(entry.name) 已在运行。请使用“应用时区”并确认正常重启。")
            }
            if let running {
                operationPhases[entry.id] = .stopping
                refresh()
                try await stop(running, name: entry.name)
                refresh()
            }
            if case .quit = operation {
                return
            }
            operationPhases[entry.id] = .starting
            refresh()
            try Task.checkCancellation()
            var environment = launchEnvironment
            environment["TZ"] = operation.timeZoneID
            let launched = try await workspace.launch(descriptor, environment: environment)
            guard launched.bundleURL.standardizedFileURL == descriptor.url.standardizedFileURL,
                  workspace.runningApplications.contains(where: {
                      $0.processID == launched.processID && $0.launchDate == launched.launchDate
                  }) else {
                throw TZBoxError("\(entry.name) 启动后未保持运行，未记录为已接管。")
            }
            lastLaunchedProcesses[entry.id] = launched.identity
            if let zone = operation.timeZoneID {
                guard let launchDate = launched.launchDate else {
                    throw TZBoxError("\(entry.name) 已启动，但系统未提供启动标识；未记录为已接管，请重新应用。")
                }
                let session = NativeSession(entryID: entry.id, processID: launched.processID, timeZoneID: zone,
                                            applicationVersion: descriptor.version)
                sessions[entry.id] = session
                records[entry.id] = NativeSessionRecord(session: session, bundleURL: descriptor.url, launchDate: launchDate)
            } else {
                sessions.removeValue(forKey: entry.id)
                records.removeValue(forKey: entry.id)
            }
            needsPersistence = true
            do { try persistSessions() }
            catch {
                persistenceFailureEntries.insert(entry.id)
                throw TZBoxError("\(entry.name) 已启动，当前进程仍被跟踪，但运行记录保存失败。请重试保存后再退出 TZBox：\(error.localizedDescription)")
            }
        } catch {
            errors[entry.id] = error.localizedDescription
            throw error
        }
    }

    private func matchingApplications(for entry: AppEntry, in processes: [NativeApplicationProcess]) -> [NativeApplicationProcess] {
        let exact = processes.filter { $0.bundleURL.standardizedFileURL == entry.applicationURL.standardizedFileURL }
        if !exact.isEmpty { return exact }
        guard let identifier = descriptors[entry.id]?.bundleIdentifier else { return [] }
        // A relocated copy is observed but is never terminated implicitly.
        return processes.filter { $0.bundleIdentifier == identifier }
    }

    private func stop(_ process: NativeApplicationProcess, name: String) async throws {
        guard workspace.runningApplications.contains(where: { process.matches($0) }) else {
            throw TZBoxError("原进程已退出或身份已变化；未操作其他应用实例。")
        }
        guard workspace.terminate(process) else {
            throw TZBoxError("\(name) 未同意正常退出，原进程与时区保持不变。请处理应用中的保存提示后重试。")
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(terminationTimeout * 1000)))
        while workspace.runningApplications.contains(where: {
            $0.processID == process.processID && $0.bundleURL == process.bundleURL && $0.launchDate == process.launchDate
        }) {
            guard ContinuousClock.now < deadline else {
                throw TZBoxError("\(name) 尚未退出，可能正在等待保存确认。TZBox 没有强制结束进程；处理提示后可重试。")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private var archiveURL: URL? { sessionDirectory?.appendingPathComponent("native-sessions.json") }

    private func restoreSessions() {
        guard let archiveURL else { return }
        let data: Data
        do {
            data = try Data(contentsOf: archiveURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch {
            restorationFailed = true
            persistenceError = "无法读取运行记录，原文件已保留。可使用“恢复运行记录”重新扫描：\(error.localizedDescription)"
            return
        }
        do {
            let saved = try JSONDecoder().decode([NativeSessionRecord].self, from: data)
            let processes = workspace.runningApplications
            for record in saved where processes.contains(where: { record.matches($0) }) {
                var session = record.session
                session.isRunning = true
                sessions[session.entryID] = session
                records[session.entryID] = record
            }
            needsPersistence = saved.count != records.count
        } catch {
            restorationFailed = true
            persistenceError = "运行记录损坏，原文件已保留。可使用“恢复运行记录”保留备份并重新扫描。"
        }
        if needsPersistence && !restorationFailed {
            do { try persistSessions() } catch { /* Preserve active sessions in memory. */ }
        }
    }

    private func persistSessions() throws {
        guard let archiveURL, let sessionDirectory else {
            needsPersistence = false
            persistenceError = nil
            return
        }
        do {
            guard !restorationFailed else { throw TZBoxError("原运行记录无法读取，请先恢复运行记录。") }
            let active = sessions.values.filter { $0.isRunning }
            let activeRecords = active.compactMap { records[$0.entryID] }
                .sorted { $0.session.entryID.uuidString < $1.session.entryID.uuidString }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(activeRecords)
            try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
            try data.write(to: archiveURL, options: .atomic)
            needsPersistence = false
            persistenceError = nil
            for id in persistenceFailureEntries { errors.removeValue(forKey: id) }
            persistenceFailureEntries.removeAll()
        } catch {
            persistenceError = "运行记录保存失败；当前进程仍被跟踪，可重试保存：\(error.localizedDescription)"
            throw error
        }
    }
}
