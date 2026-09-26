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

// The launch date distinguishes the original application from a reused process ID.
struct NativeSessionRecord: Codable {
    let session: NativeSession
    let bundleURL: URL
    let launchDate: Date

    func matches(_ application: NSRunningApplication) -> Bool {
        !application.isTerminated
            && application.bundleURL?.standardizedFileURL == bundleURL.standardizedFileURL
            && application.launchDate == launchDate
    }
}

@MainActor
public final class NativeLauncher: ObservableObject {
    @Published public private(set) var sessions: [UUID: NativeSession] = [:]
    @Published public private(set) var persistenceError: String?
    private let notificationCenter: NotificationCenter
    private let sessionDirectory: URL?
    private var records: [UUID: NativeSessionRecord] = [:]
    private var restorationFailed = false
    private var needsPersistence = false
    private var terminationObserver: NSObjectProtocol?
    private var launchingEntries: Set<UUID> = []

    public init(sessionDirectory: URL? = nil) {
        self.sessionDirectory = sessionDirectory
        notificationCenter = NSWorkspace.shared.notificationCenter
        restoreSessions()
        terminationObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let owner = self else { return }
            Task { @MainActor in owner.refresh() }
        }
    }

    deinit {
        if let terminationObserver {
            notificationCenter.removeObserver(terminationObserver)
        }
    }

    public var hasRunningApplications: Bool {
        !launchingEntries.isEmpty || sessions.values.contains { $0.isRunning }
    }

    public func isRunning(_ entryID: UUID) -> Bool {
        sessions[entryID]?.isRunning == true || launchingEntries.contains(entryID)
    }

    public func launch(entry: AppEntry, timeZoneID: String) async throws {
        guard !restorationFailed else {
            throw TZBoxError(persistenceError ?? "无法恢复应用会话；请修复记录文件后重新打开 TZBox。")
        }
        guard entry.backend == .native else {
            throw TZBoxError("Chrome 请使用专用启动入口。")
        }
        guard TimeZones.isValid(timeZoneID) else {
            throw TZBoxError("无效的 IANA 时区：\(timeZoneID)")
        }
        let url = entry.applicationURL.standardizedFileURL
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url), let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw TZBoxError("请选择包含可执行文件的 macOS .app 应用。")
        }
        refresh()
        guard !isRunning(entry.id) else {
            throw TZBoxError("\(entry.name) 已启动或正在启动。")
        }
        let alreadyRunning = NSWorkspace.shared.runningApplications.contains { application in
            let samePath = application.bundleURL?.standardizedFileURL == url
            let sameIdentifier = bundle.bundleIdentifier.map { $0 == application.bundleIdentifier } ?? false
            return !application.isTerminated && (samePath || sameIdentifier)
        }
        guard !alreadyRunning else {
            throw TZBoxError("\(entry.name) 已在运行；请先正常退出，再从 TZBox 启动。")
        }

        launchingEntries.insert(entry.id)
        objectWillChange.send()
        defer {
            launchingEntries.remove(entry.id)
            objectWillChange.send()
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.environment = ["TZ": timeZoneID]
        let application: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let application {
                    continuation.resume(returning: application)
                } else {
                    continuation.resume(throwing: TZBoxError("系统未返回已启动的应用。"))
                }
            }
        }
        guard !application.isTerminated else {
            throw TZBoxError("\(entry.name) 启动后立即退出，时区效果未经验证。")
        }
        let session = NativeSession(
            entryID: entry.id,
            processID: application.processIdentifier,
            timeZoneID: timeZoneID,
            applicationVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        )
        sessions[entry.id] = session
        if let launchDate = application.launchDate {
            records[entry.id] = NativeSessionRecord(session: session, bundleURL: url, launchDate: launchDate)
        }
        needsPersistence = true
        do {
            try persistSessions()
        } catch {
            throw TZBoxError("\(entry.name) 已启动且仍受跟踪，但会话保存失败。退出 TZBox 前请正常关闭该应用。\(error.localizedDescription)")
        }
        // Starting an application provides no evidence that its time APIs respect TZ.
    }

    public func activate(_ entryID: UUID) {
        guard let session = sessions[entryID], session.isRunning,
              let application = NSRunningApplication(processIdentifier: session.processID) else { return }
        if let record = records[entryID], !record.matches(application) { return }
        application.activate(options: [.activateAllWindows])
    }

    public func refresh() {
        for (id, session) in sessions where session.isRunning {
            let application = NSRunningApplication(processIdentifier: session.processID)
            let stillRunning = application.map { candidate in
                records[id]?.matches(candidate) ?? !candidate.isTerminated
            } ?? false
            if !stillRunning {
                sessions[id]?.isRunning = false
                records.removeValue(forKey: id)
                needsPersistence = true
            }
        }
        if needsPersistence && !restorationFailed {
            do { try persistSessions() } catch { /* persistenceError is exposed to the UI. */ }
        }
    }

    private var archiveURL: URL? {
        sessionDirectory?.appendingPathComponent("native-sessions.json")
    }

    private func restoreSessions() {
        guard let archiveURL else { return }
        let data: Data
        do {
            data = try Data(contentsOf: archiveURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch {
            restorationFailed = true
            persistenceError = "无法读取应用会话；原文件已保留。修复后请重新打开 TZBox：\(error.localizedDescription)"
            return
        }
        do {
            let saved = try JSONDecoder().decode([NativeSessionRecord].self, from: data)
            for record in saved {
                guard let application = NSRunningApplication(processIdentifier: record.session.processID),
                      record.matches(application) else { continue }
                var session = record.session
                session.isRunning = true
                sessions[session.entryID] = session
                records[session.entryID] = record
            }
            needsPersistence = saved.count != records.count
        } catch {
            restorationFailed = true
            persistenceError = "应用会话记录损坏；原文件已保留。修复后请重新打开 TZBox：\(error.localizedDescription)"
            return
        }
        if needsPersistence {
            do { try persistSessions() } catch { /* Keep the original file and surface the failure. */ }
        }
    }

    private func persistSessions() throws {
        guard let archiveURL, let sessionDirectory else {
            needsPersistence = false
            return
        }
        do {
            guard !restorationFailed else {
                throw TZBoxError("原会话无法读取，不能覆盖。")
            }
            let activeSessions = sessions.values.filter { $0.isRunning }
            guard activeSessions.allSatisfy({ records[$0.entryID] != nil }) else {
                throw TZBoxError("系统未提供部分应用的启动标识；请先正常关闭这些应用。")
            }
            let activeRecords = activeSessions.compactMap { records[$0.entryID] }
                .sorted { $0.session.entryID.uuidString < $1.session.entryID.uuidString }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(activeRecords)
            try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
            try data.write(to: archiveURL, options: .atomic)
            needsPersistence = false
            persistenceError = nil
        } catch {
            persistenceError = "应用会话保存失败，现有会话仍在内存中跟踪：\(error.localizedDescription)"
            throw error
        }
    }
}
