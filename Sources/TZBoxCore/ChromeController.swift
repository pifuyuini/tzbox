import AppKit
import Combine
import Darwin
import Foundation

public enum ChromeState: String {
    case stopped, starting, running, interrupted, stopping, failed
}

@MainActor
public final class ChromeController: ObservableObject {
    @Published public private(set) var state: ChromeState = .stopped
    @Published public private(set) var report: VerificationReport?
    @Published public private(set) var message = "尚未启动 Chrome"

    public var isActive: Bool { state == .starting || process?.isRunning == true }
    public var processID: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    let profileDirectory: URL
    private let endpointTimeout: TimeInterval
    private var process: Process?
    private var endpoint: URL?
    private var heartbeat: Task<Void, Never>?
    private var recovery: Task<Void, Never>?
    private var isReconnecting = false
    private var operationGeneration = 0
    private var connectionGeneration = 0
    private var failedTargetIDs: [String: String] = [:]
    private var criticalFailures: [String: VerificationCheck] = [:]
    private var workerWarnings: [String: VerificationCheck] = [:]
    private var preparationTasks: [String: Task<Void, Never>] = [:]
    private var targetFailures: [String: String] = [:]
    private var preparedSessions: Set<String> = []
    private(set) var client: CDPClient?
    private(set) var timeZoneID = ""
    private(set) var applicationVersion = "unknown"

    struct Target {
        let id: String
        let sessionID: String
        let kind: String
        let parentSessionID: String?
    }
    private(set) var targets: [String: Target] = [:]

    public convenience init(profileDirectory: URL) {
        self.init(profileDirectory: profileDirectory, endpointTimeout: 15)
    }

    init(profileDirectory: URL, endpointTimeout: TimeInterval) {
        self.profileDirectory = profileDirectory
        self.endpointTimeout = endpointTimeout
    }

    public func launch(applicationURL: URL, timeZoneID: String) async throws {
        guard !isActive else { throw TZBoxError("请先正常关闭 TZBox 启动的 Chrome。") }
        guard TimeZones.isValid(timeZoneID) else { throw TZBoxError("请选择有效的 IANA 时区。") }
        guard applicationURL.pathExtension == "app",
              let executable = Bundle(url: applicationURL)?.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw TZBoxError("所选应用没有可执行文件，请选择 Google Chrome.app。")
        }
        operationGeneration += 1
        let operation = operationGeneration
        state = .starting
        report = nil
        message = "正在启动独立 Chrome 资料…"
        self.timeZoneID = timeZoneID
        do {
            try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
            try await rejectExistingProfileProcess()
            guard operation == operationGeneration, state == .starting else { throw CancellationError() }
            let portFile = profileDirectory.appendingPathComponent("DevToolsActivePort")
            if FileManager.default.fileExists(atPath: portFile.path) {
                try FileManager.default.removeItem(at: portFile)
            }
            let launched = Process()
            launched.executableURL = executable
            launched.arguments = [
                "--user-data-dir=\(profileDirectory.path)", "--remote-debugging-address=127.0.0.1",
                "--remote-debugging-port=0", "--no-startup-window", "--no-first-run",
                "--no-default-browser-check", "--disable-session-crashed-bubble"
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["TZ"] = timeZoneID
            launched.environment = environment
            launched.standardOutput = FileHandle.nullDevice
            launched.standardError = FileHandle.nullDevice
            launched.terminationHandler = { [weak self] ended in
                guard let owner = self else { return }
                Task { @MainActor in
                    guard owner.process === ended else { return }
                    owner.didExit()
                }
            }
            process = launched
            try launched.run()
            endpoint = try await awaitEndpoint()
            try await connect()
            guard let connection = client else { throw TZBoxError("Chrome 控制连接不存在。") }
            let generation = connectionGeneration
            _ = try await createPage(url: "about:blank")
            let initialReport = try await performBasicCheck()
            try validateOperation(operation, generation: generation, connection: connection)
            publishReport(initialReport, message: "Chrome 已启动；各项验证结果见报告。")
            guard report?.checks.contains(where: { $0.outcome == .failed }) == false else {
                throw TZBoxError("当前检查页未通过时区验证。")
            }
            state = .running
            startHeartbeat()
            activate()
        } catch {
            guard operation == operationGeneration else { throw error }
            state = process?.isRunning == true ? .interrupted : .failed
            message = process?.isRunning == true
                ? "Chrome 已启动，但控制未就绪：\(error.localizedDescription)。可重连或正常关闭。"
                : "Chrome 启动失败：\(error.localizedDescription)"
            if process?.isRunning == true { scheduleRecovery() }
            throw error
        }
    }

    public func check() async throws -> VerificationReport {
        guard isActive, state != .stopping, let connection = client, connection.isConnected else {
            throw TZBoxError("请先启动 Chrome 或恢复控制连接。")
        }
        let operation = operationGeneration
        let generation = connectionGeneration
        do {
            let checked = try await performBasicCheck()
            try validateOperation(operation, generation: generation, connection: connection)
            publishReport(checked, message: "已检查当前诊断页；iframe 和 Worker 需要开发诊断验证。")
            if report?.checks.contains(where: { $0.outcome == .failed }) == true {
                state = .interrupted
                message = "当前连接有未通过的时区验证，详情见报告。"
            }
            return report ?? checked
        } catch {
            if operation == operationGeneration, client === connection {
                if criticalFailures.isEmpty { report = nil }
                message = "时区检查未完成：\(error.localizedDescription)"
            }
            throw error
        }
    }

    public func close() async -> Bool {
        operationGeneration += 1
        guard let process, process.isRunning else { didExit(); return true }
        recovery?.cancel()
        recovery = nil
        heartbeat?.cancel()
        heartbeat = nil
        state = .stopping
        message = "正在请求 Chrome 正常退出…"
        if client?.isConnected != true {
            do { try await connect() }
            catch {
                state = .interrupted
                message = "无法发送正常退出请求，请在受控 Chrome 中退出后重试：\(error.localizedDescription)"
                return false
            }
        }
        // Browser.close may close the socket before its reply reaches us.
        _ = try? await client?.request("Browser.close", timeout: 2)
        for _ in 0..<50 {
            if !process.isRunning { didExit(); return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        state = .interrupted
        message = "Chrome 尚未退出，请处理浏览器中的确认窗口；TZBox 将继续运行。"
        startHeartbeat()
        return false
    }

    public func activate() {
        guard let processID else { return }
        NSRunningApplication(processIdentifier: processID)?.activate(options: [])
    }

    public func reconnect() async throws {
        guard !isReconnecting, state != .stopping else { throw TZBoxError("Chrome 控制正在恢复或退出，请稍候。") }
        operationGeneration += 1
        let operation = operationGeneration
        isReconnecting = true
        defer { isReconnecting = false }
        guard process?.isRunning == true else { throw TZBoxError("受控 Chrome 已退出，请重新启动。") }
        state = .interrupted
        report = nil
        message = "正在恢复 Chrome 控制…"
        try await connect()
        guard let connection = client else { throw TZBoxError("Chrome 控制连接不存在。") }
        let generation = connectionGeneration
        let checked = try await performBasicCheck()
        try validateOperation(operation, generation: generation, connection: connection)
        publishReport(checked, message: "已重新检查当前诊断页；其他环境见验证报告。")
        guard report?.checks.contains(where: { $0.outcome == .failed }) == false else {
            throw TZBoxError("控制已连接，但当前检查页未通过时区验证。")
        }
        state = .running
        startHeartbeat()
    }

    func publishReport(_ checked: VerificationReport, message: String) {
        let additional = Array(criticalFailures.values) + Array(workerWarnings.values)
        let names = Set(additional.map(\.name))
        report = VerificationReport(applicationVersion: checked.applicationVersion, timeZoneID: checked.timeZoneID,
                                    checkedAt: checked.checkedAt,
                                    checks: checked.checks.filter { !names.contains($0.name) } + additional.sorted { $0.name < $1.name })
        self.message = message
        if !criticalFailures.isEmpty, state != .stopping { state = .interrupted }
    }

    private func validateOperation(_ operation: Int, generation: Int, connection: CDPClient) throws {
        guard operation == operationGeneration, generation == connectionGeneration,
              client === connection, connection.isConnected, process?.isRunning == true, state != .stopping else {
            throw TZBoxError("操作期间 Chrome 状态或控制连接已变化，请重新检查。")
        }
    }

    private func rejectExistingProfileProcess() async throws {
        let lock = profileDirectory.appendingPathComponent("SingletonLock")
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: lock.path),
           let component = destination.split(separator: "-").last,
           let pid = Int32(component), pid > 0,
           kill(pid, 0) == 0 || errno == EPERM {
            throw TZBoxError("这份 TZBox Chrome 资料已有运行实例，请先正常退出该实例。")
        }
        if let existing = readEndpoint() {
            var components = URLComponents(url: existing, resolvingAgainstBaseURL: false)!
            components.scheme = "http"
            components.path = "/json/version"
            let request = URLRequest(url: components.url!, timeoutInterval: 1)
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let response = response as? HTTPURLResponse, response.statusCode == 200 {
                throw TZBoxError("这份 Chrome 资料的调试端点仍在使用，请先正常退出原实例。")
            }
        }
    }

    private func readEndpoint() -> URL? {
        let file = profileDirectory.appendingPathComponent("DevToolsActivePort")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count >= 2, let port = Int(lines[0]), (1...65535).contains(port),
              lines[1].hasPrefix("/devtools/browser/"), !lines[1].contains("?") else { return nil }
        var components = URLComponents()
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = port
        components.path = String(lines[1])
        return components.url
    }

    private func awaitEndpoint() async throws -> URL {
        let deadline = Date().addingTimeInterval(endpointTimeout)
        while Date() < deadline {
            guard process?.isRunning == true else {
                throw TZBoxError("Chrome 在建立控制连接前退出。请确认选择的是 Google Chrome。")
            }
            if let endpoint = readEndpoint() { return endpoint }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw TZBoxError("等待 Chrome 本机调试端点超时。")
    }

    private func connect() async throws {
        connectionGeneration += 1
        heartbeat?.cancel()
        heartbeat = nil
        client?.close()
        cancelPreparation()
        guard let endpoint = readEndpoint() ?? endpoint else { throw TZBoxError("找不到 Chrome 控制端点。") }
        self.endpoint = endpoint
        let connection = CDPClient(url: endpoint)
        client = connection
        connection.onEvent = { [weak self, weak connection] method, params, parentSession in
            guard let self, self.client === connection else { return }
            self.handleEvent(method: method, params: params, parentSessionID: parentSession)
        }
        connection.onDisconnect = { [weak self, weak connection] error in
            guard let self, self.client === connection, self.state != .stopping else { return }
            self.report = nil
            if self.process?.isRunning == true {
                self.state = .interrupted
                self.message = "Chrome 控制中断：\(error.localizedDescription)"
                self.scheduleRecovery()
            } else { self.didExit() }
        }
        connection.start()
        do {
            let version = try await connection.request("Browser.getVersion")
            applicationVersion = version["product"] as? String ?? "unknown"
            _ = try await connection.request("Target.setDiscoverTargets", params: ["discover": true])
            _ = try await connection.request("Target.setAutoAttach", params: [
                "autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true,
                "filter": [["type": "browser", "exclude": true], [:]]
            ])
            let snapshot = try await connection.request("Target.getTargets")
            for item in snapshot["targetInfos"] as? [[String: Any]] ?? [] {
                if let kind = item["type"] as? String, ["page", "iframe"].contains(kind),
                   let id = item["targetId"] as? String {
                    _ = try await waitForTarget(id)
                }
            }
        } catch {
            connection.close()
            throw error
        }
    }

    private func handleEvent(method: String, params: [String: Any], parentSessionID: String?) {
        if method == "Target.attachedToTarget",
           let sessionID = params["sessionId"] as? String,
           let info = params["targetInfo"] as? [String: Any],
           let id = info["targetId"] as? String,
           let kind = info["type"] as? String,
           let connection = client {
            let target = Target(id: id, sessionID: sessionID, kind: kind, parentSessionID: parentSessionID)
            targets[sessionID] = target
            let preparation = Task { [weak self] in
                guard let self else { return }
                var preparationError: Error?
                do {
                    // Auto-attachment only covers related targets; repeat it at each parent.
                    if ["page", "iframe", "tab"].contains(kind) {
                        _ = try await connection.request("Target.setAutoAttach", params: [
                            "autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true,
                            "filter": [["type": "browser", "exclude": true], [:]]
                        ], sessionID: sessionID)
                    }
                    _ = try await connection.request("Emulation.setTimezoneOverride",
                                                     params: ["timezoneId": self.timeZoneID], sessionID: sessionID)
                } catch { preparationError = error }
                guard self.client === connection, self.targets[sessionID] != nil else { return }
                if let preparationError, ["page", "iframe"].contains(kind) {
                    let detail = preparationError.localizedDescription
                    self.targetFailures[sessionID] = detail
                    self.failedTargetIDs[id] = detail
                    let name = "\(kind == "page" ? "网页" : "子页面")时区覆盖（\(id.prefix(8))）"
                    self.criticalFailures[id] = VerificationCheck(name: name, outcome: .failed,
                        detail: "时区设置失败；该页面不会被放行，已请求正常关闭。\(detail)")
                    let existing = self.report ?? VerificationReport(applicationVersion: self.applicationVersion,
                                                                    timeZoneID: self.timeZoneID, checks: [])
                    self.publishReport(existing, message: "页面时区设置失败，已请求关闭该页面：\(detail)")
                    // Close the owning page for an OOPIF; never resume an unconfigured page.
                    var owner = target
                    while owner.kind != "page", let parentID = owner.parentSessionID,
                          let parent = self.targets[parentID] { owner = parent }
                    let result = try? await connection.request("Target.closeTarget", params: ["targetId": owner.id], timeout: 2)
                    if result?["success"] as? Bool != true, self.client === connection {
                        self.message = "页面时区设置失败，且尚未关闭；请在 Chrome 中关闭该页或正常退出 Chrome。"
                    }
                    self.preparationTasks.removeValue(forKey: sessionID)
                    return
                }
                // Unsupported worker domains must never leave a worker paused indefinitely.
                _ = try? await connection.request("Runtime.runIfWaitingForDebugger", sessionID: sessionID, timeout: 2)
                guard self.client === connection, self.targets[sessionID] != nil else { return }
                if let preparationError {
                    self.targetFailures[sessionID] = preparationError.localizedDescription
                    if ["worker", "shared_worker", "service_worker"].contains(kind) {
                        let warning = VerificationCheck(name: "\(kind) / CDP 时区能力", outcome: .unverified,
                            detail: "该执行环境不接受时区覆盖命令，已解除启动暂停；实际时区需要独立探针确认。\(preparationError.localizedDescription)")
                        self.workerWarnings[kind] = warning
                        let existing = self.report ?? VerificationReport(applicationVersion: self.applicationVersion,
                                                                        timeZoneID: self.timeZoneID, checks: [])
                        self.publishReport(existing, message: "Worker 时区能力尚未确认，详见验证报告。")
                    }
                } else { self.preparedSessions.insert(sessionID) }
                self.preparationTasks.removeValue(forKey: sessionID)
            }
            preparationTasks[sessionID] = preparation
        } else if method == "Target.detachedFromTarget", let sessionID = params["sessionId"] as? String {
            preparationTasks.removeValue(forKey: sessionID)?.cancel()
            targets.removeValue(forKey: sessionID)
            targetFailures.removeValue(forKey: sessionID)
            preparedSessions.remove(sessionID)
        } else if method == "Target.targetDestroyed", let id = params["targetId"] as? String {
            for target in targets.values.filter({ $0.id == id }) {
                preparationTasks.removeValue(forKey: target.sessionID)?.cancel()
                targets.removeValue(forKey: target.sessionID)
                targetFailures.removeValue(forKey: target.sessionID)
                preparedSessions.remove(target.sessionID)
            }
        }
    }

    func createPage(url: String) async throws -> Target {
        guard let client else { throw TZBoxError("Chrome 控制连接不存在。") }
        let result = try await client.request("Target.createTarget", params: ["url": url])
        guard let id = result["targetId"] as? String else { throw TZBoxError("Chrome 未返回新页面标识。") }
        do { return try await waitForTarget(id) }
        catch {
            _ = try? await client.request("Target.closeTarget", params: ["targetId": id], timeout: 2)
            throw error
        }
    }

    func waitForTarget(_ id: String) async throws -> Target {
        for _ in 0..<200 {
            if let failure = failedTargetIDs[id] { throw TZBoxError(failure) }
            guard client?.isConnected == true else { throw TZBoxError("等待页面时 Chrome 控制中断。") }
            if let target = targets.values.first(where: { $0.id == id }) {
                if let failure = targetFailures[target.sessionID] { throw TZBoxError(failure) }
                if preparedSessions.contains(target.sessionID) { return target }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw TZBoxError("等待 Chrome 页面时区覆盖超时。")
    }

    func evaluate(sessionID: String, expression: String) async throws -> Any {
        guard let client else { throw TZBoxError("Chrome 控制连接不存在。") }
        let response = try await client.request("Runtime.evaluate", params: [
            "expression": expression, "returnByValue": true, "awaitPromise": true, "userGesture": true
        ], sessionID: sessionID, timeout: 12)
        if let exception = response["exceptionDetails"] as? [String: Any] {
            throw TZBoxError("页面探针执行失败：\(exception["text"] as? String ?? "JavaScript exception")")
        }
        guard let result = response["result"] as? [String: Any], let value = result["value"] else {
            throw TZBoxError("页面探针没有返回可读取的结果。")
        }
        return value
    }

    func closeTarget(_ id: String) async {
        _ = try? await client?.request("Target.closeTarget", params: ["targetId": id], timeout: 2)
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                guard let self, self.process?.isRunning == true, let connection = self.client else { return }
                do { _ = try await connection.request("Browser.getVersion", timeout: 3) }
                catch {
                    guard !Task.isCancelled, self.state != .stopping else { return }
                    connection.close()
                    self.report = nil
                    self.state = .interrupted
                    self.message = "Chrome 控制连接无响应。"
                    self.scheduleRecovery()
                    return
                }
            }
        }
    }

    private func scheduleRecovery() {
        guard recovery == nil else { return }
        recovery = Task { [weak self] in
            defer { self?.recovery = nil }
            for delay in [1, 2, 4] {
                do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) }
                catch { return }
                guard let self, self.process?.isRunning == true, self.state != .stopping else { return }
                do { try await self.reconnect(); return }
                catch {
                    guard !Task.isCancelled else { return }
                    self.message = "控制恢复未完成：\(error.localizedDescription)"
                }
            }
            self?.message = "自动重连未成功，请点击重连；仍需正常关闭受控 Chrome 才能更改时区。"
        }
    }

    private func cancelPreparation() {
        for task in preparationTasks.values { task.cancel() }
        preparationTasks.removeAll()
        targets.removeAll()
        targetFailures.removeAll()
        preparedSessions.removeAll()
        failedTargetIDs.removeAll()
        criticalFailures.removeAll()
        workerWarnings.removeAll()
    }

    private func didExit() {
        operationGeneration += 1
        connectionGeneration += 1
        recovery?.cancel()
        recovery = nil
        heartbeat?.cancel()
        heartbeat = nil
        client?.close()
        client = nil
        cancelPreparation()
        process = nil
        endpoint = nil
        report = nil
        state = .stopped
        message = "Chrome 已退出；专用登录资料已保留。"
    }
}
