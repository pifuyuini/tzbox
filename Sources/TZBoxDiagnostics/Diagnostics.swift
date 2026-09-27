import AppKit
import Darwin
import Foundation
import TZBoxCore

private func snapshot() -> [String: Any] {
    tzset()
    var seconds = time(nil)
    var local = tm()
    localtime_r(&seconds, &local)
    return [
        "processID": ProcessInfo.processInfo.processIdentifier,
        "environmentTZ": ProcessInfo.processInfo.environment["TZ"] ?? "",
        "timestamp": Date().timeIntervalSince1970,
        "foundationZone": TimeZone.current.identifier,
        "foundationOffsetSeconds": TimeZone.current.secondsFromGMT(),
        "posixOffsetSeconds": Int(local.tm_gmtoff),
        "posixZone": local.tm_zone.map { String(cString: $0) } ?? ""
    ]
}
private func encoded(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
private func send(_ object: Any) throws {
    FileHandle.standardOutput.write(try encoded(object))
    FileHandle.standardOutput.write(Data("\n".utf8))
}
private final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let output: URL
    init(output: URL) { self.output = output }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            var result = snapshot()
            let child = Process()
            child.executableURL = Bundle.main.executableURL
            child.arguments = ["probe-child"]
            let pipe = Pipe()
            child.standardOutput = pipe
            try child.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            guard child.terminationStatus == 0 else { throw TZBoxError("测试子进程失败") }
            result["child"] = try JSONSerialization.jsonObject(with: data)
            try encoded(result).write(to: output, options: .atomic)
        } catch { fputs("Probe error: \(error.localizedDescription)\n", stderr) }
        if Bundle.main.object(forInfoDictionaryKey: "TZBoxProbeKeepAlive") as? Bool != true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApplication.shared.terminate(nil) }
        }
    }
}
private struct LaunchOptions: Decodable {
    let arguments: [String]
    let environment: [String: String]
    let excludedProcessIDs: [Int32]?
}

@main
private struct Diagnostics {
    @MainActor
    static func main() async {
        do {
            if CommandLine.arguments.dropFirst().first == "probe-child" {
                try send(snapshot()); return
            }
            if let path = Bundle.main.object(forInfoDictionaryKey: "TZBoxProbeOutput") as? String {
                let delegate = ProbeDelegate(output: URL(fileURLWithPath: path))
                let app = NSApplication.shared
                app.setActivationPolicy(.prohibited)
                app.delegate = delegate
                withExtendedLifetime(delegate) { app.run() }
                return
            }
            let args = Array(CommandLine.arguments.dropFirst())
            switch args.first {
            case "native-lifecycle":
                guard args.count == 3 else { throw TZBoxError("native-lifecycle APP OUTPUT") }
                try await nativeLifecycle(appURL: URL(fileURLWithPath: args[1]), outputURL: URL(fileURLWithPath: args[2]))
            case "session":
                guard args.count == 3 else { throw TZBoxError("session APP CONTROL_ROOT") }
                try await session(appURL: URL(fileURLWithPath: args[1]), root: URL(fileURLWithPath: args[2]))
            default:
                throw TZBoxError("Developer harness: native-lifecycle APP OUTPUT | session APP CONTROL_ROOT")
            }
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func session(appURL: URL, root: URL) async throws {
        let options = try JSONDecoder().decode(LaunchOptions.self, from: Data(contentsOf: root.appendingPathComponent("launch-options.json")))
        let entry = AppEntry(name: appURL.deletingPathExtension().lastPathComponent, applicationURL: appURL, backend: .native)
        let launcher = NativeLauncher(sessionDirectory: root.appendingPathComponent("sessions"),
                                      launchArguments: options.arguments, launchEnvironment: options.environment,
                                      excludedProcessIDs: Set(options.excludedProcessIDs ?? []))
        var ownedProcess: ApplicationProcessIdentity?
        func state(ok: Bool, error: String? = nil) -> [String: Any] {
            launcher.refresh(entries: [entry])
            let runtime = launcher.runtime(for: entry)
            var value: [String: Any] = [
                "ok": ok, "isRunning": runtime.isRunning, "isManaged": runtime.isManaged,
                "timeZoneID": runtime.timeZoneID ?? "", "processID": runtime.processID ?? 0,
                "systemTimeZoneID": TimeZone.autoupdatingCurrent.identifier,
                "sampledAt": Date().timeIntervalSince1970
            ]
            if let error { value["error"] = error }
            return value
        }
        func rememberLaunch() {
            if let launched = launcher.lastLaunchedProcessIdentity(for: entry) { ownedProcess = launched }
        }
        func closeOwnedProcess() async throws {
            launcher.refresh(entries: [entry])
            guard let own = ownedProcess else { return }
            guard launcher.isRunning(own) else { ownedProcess = nil; return }
            // The quit operation and final runtime adapter recheck this exact
            // identity. A process replacing it at the same path is not selected.
            try await launcher.quit(entry: entry, expectedProcess: own)
            ownedProcess = nil
        }
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                do {
                    guard let command = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let action = command["action"] as? String else { throw TZBoxError("命令必须包含 action") }
                    switch action {
                    case "apply":
                        guard let zone = command["timeZoneID"] as? String else { throw TZBoxError("缺少 timeZoneID") }
                        try await launcher.apply(entry: entry, timeZoneID: zone, expectedProcess: ownedProcess)
                        rememberLaunch()
                    case "restore":
                        try await launcher.restoreSystem(entry: entry, expectedProcess: ownedProcess)
                        rememberLaunch()
                    case "quit":
                        try await closeOwnedProcess()
                    case "status":
                        break
                    case "exit":
                        try await closeOwnedProcess()
                        try send(state(ok: true))
                        return
                    default: throw TZBoxError("未知诊断操作")
                    }
                    try send(state(ok: true))
                } catch {
                    // A successful launch followed by a save failure still belongs
                    // to this driver; the core records its identity before saving.
                    rememberLaunch()
                    try send(state(ok: false, error: error.localizedDescription))
                }
            }
            try await closeOwnedProcess()
        } catch {
            try? await closeOwnedProcess()
            throw error
        }
    }

    @MainActor
    private static func readProbe(_ output: URL, after start: Date, processID: Int32) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let data = try? Data(contentsOf: output),
               let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let stamp = result["timestamp"] as? Double, stamp >= start.timeIntervalSince1970,
               result["processID"] as? Int == Int(processID) {
                return result
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw TZBoxError("测试应用没有写出本次启动结果")
    }

    private static func validateNativeProbe(appURL: URL, outputURL: URL) throws -> URL {
        guard let rootPath = ProcessInfo.processInfo.environment["TZBOX_TEST_ROOT"], !rootPath.isEmpty else {
            throw TZBoxError("native-lifecycle 仅接受本次 TZBOX_TEST_ROOT 内的自有测试探针。")
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tmp = repository.appendingPathComponent("tmp", isDirectory: true).resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        let marker = root.appendingPathComponent(".codex-tmp")
        guard root == resolvedRoot, root.path.hasPrefix(tmp.path + "/"),
              let markerInfo = try? marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              markerInfo.isRegularFile == true, markerInfo.isSymbolicLink != true else {
            throw TZBoxError("native-lifecycle 需要仓库 tmp 内带 .codex-tmp 标记的本次测试目录。")
        }
        let application = appURL.standardizedFileURL
        let output = outputURL.standardizedFileURL
        guard application == application.resolvingSymlinksInPath(),
              application.path.hasPrefix(root.path + "/"),
              output == output.resolvingSymlinksInPath(),
              output.deletingLastPathComponent() == root,
              let bundle = Bundle(url: application), bundle.bundleIdentifier == "dev.tzbox.probe",
              bundle.object(forInfoDictionaryKey: "TZBoxProbeKeepAlive") as? Bool == true,
              let configuredOutput = bundle.object(forInfoDictionaryKey: "TZBoxProbeOutput") as? String,
              URL(fileURLWithPath: configuredOutput).standardizedFileURL == output else {
            throw TZBoxError("仅可运行本次目录内的 dev.tzbox.probe，且 Info.plist 的输出路径必须与请求一致。")
        }
        return root
    }

    @MainActor
    private static func nativeLifecycle(appURL: URL, outputURL: URL) async throws {
        let root = try validateNativeProbe(appURL: appURL, outputURL: outputURL)
        guard !NSWorkspace.shared.runningApplications.contains(where: {
            !$0.isTerminated && ($0.bundleIdentifier == "dev.tzbox.probe"
                || $0.bundleURL?.standardizedFileURL == appURL.standardizedFileURL)
        }) else {
            throw TZBoxError("自有探针已有运行实例；本次测试不会重启或关闭既有实例。")
        }
        let systemZone = TimeZone.autoupdatingCurrent.identifier
        let directory = root.appendingPathComponent("native-session-store")
        let entry = AppEntry(name: "TZBox 自有测试应用", applicationURL: appURL, backend: .native)
        var launcher = NativeLauncher(sessionDirectory: directory)
        var ownedProcess: ApplicationProcessIdentity?
        var checks: [VerificationCheck] = []
        func record(_ name: String, _ success: Bool, _ detail: String) {
            checks.append(VerificationCheck(name: name, outcome: success ? .passed : .failed, detail: detail))
        }
        func rememberLaunch() throws -> ApplicationProcessIdentity {
            guard let launched = launcher.lastLaunchedProcessIdentity(for: entry) else {
                throw TZBoxError("未获得本次启动的进程身份，不能执行后续诊断操作。")
            }
            ownedProcess = launched
            return launched
        }
        do {
            for (index, zoneID) in ["America/New_York", "Asia/Kolkata"].enumerated() {
                let before = Date()
                let previousPID = ownedProcess?.processID
                try await launcher.apply(entry: entry, timeZoneID: zoneID, expectedProcess: ownedProcess)
                let launched = try rememberLaunch()
                let result = try await readProbe(outputURL, after: before, processID: launched.processID)
                let after = Date()
                let child = result["child"] as? [String: Any] ?? [:]
                let offset = TimeZone(identifier: zoneID)!.secondsFromGMT(for: before)
                record("\(zoneID) 环境传递", result["environmentTZ"] as? String == zoneID && child["environmentTZ"] as? String == zoneID, "目标与子进程")
                record("\(zoneID) 时间转换", result["posixOffsetSeconds"] as? Int == offset && result["foundationOffsetSeconds"] as? Int == offset && child["posixOffsetSeconds"] as? Int == offset && child["foundationOffsetSeconds"] as? Int == offset, "POSIX 与 Foundation")
                let stamps = [result["timestamp"] as? Double, child["timestamp"] as? Double].compactMap { $0 }
                record("\(zoneID) 真实时刻", stamps.count == 2 && stamps.allSatisfy { $0 >= before.timeIntervalSince1970 && $0 <= after.timeIntervalSince1970 }, "目标与子进程均在宿主采样区间")
                record("\(zoneID) 受管状态", launcher.runtime(for: entry).isManaged && launcher.runtime(for: entry).timeZoneID == zoneID, "实际运行时区")
                if index == 0 {
                    launcher = NativeLauncher(sessionDirectory: directory)
                    launcher.refresh(entries: [entry])
                    record("恢复已有受管会话", launcher.runtime(for: entry).isManaged && launcher.runtime(for: entry).timeZoneID == zoneID, "控制器重建后实际进程仍被识别")
                } else {
                    record("正常重启切换时区", previousPID != launched.processID, "原实例正常退出后得到新进程")
                }
            }
            let beforeRestore = Date()
            try await launcher.restoreSystem(entry: entry, expectedProcess: ownedProcess)
            let restoredProcess = try rememberLaunch()
            let restored = try await readProbe(outputURL, after: beforeRestore, processID: restoredProcess.processID)
            record("恢复系统默认环境", restored["environmentTZ"] as? String == "", "新进程不残留 TZ")
            record("恢复系统默认时区", restored["foundationOffsetSeconds"] as? Int == TimeZone.autoupdatingCurrent.secondsFromGMT(), "\(restored["foundationZone"] ?? "")")
            record("恢复后不误报受管", !launcher.runtime(for: entry).isManaged && launcher.runtime(for: entry).isRunning, "应用仍正常运行")
            try await launcher.quit(entry: entry, expectedProcess: restoredProcess)
            ownedProcess = nil
            record("正常退出应用", !launcher.runtime(for: entry).isRunning, "不使用强制终止")
        } catch {
            if let launched = launcher.lastLaunchedProcessIdentity(for: entry) { ownedProcess = launched }
            launcher.refresh(entries: [entry])
            if let own = ownedProcess, launcher.isRunning(own) {
                try? await launcher.quit(entry: entry, expectedProcess: own)
            }
            throw error
        }
        record("宿主时区不变", TimeZone.autoupdatingCurrent.identifier == systemZone, systemZone)
        let report = VerificationReport(applicationVersion: "TZBox 自有生命周期探针 0.2.0", timeZoneID: "America/New_York → Asia/Kolkata → system", checks: checks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
        guard report.passed else { throw TZBoxError("统一代理生命周期测试未通过") }
    }
}
