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
        "environmentTZ": ProcessInfo.processInfo.environment["TZ"] ?? "",
        "timestamp": Date().timeIntervalSince1970,
        "foundationZone": TimeZone.current.identifier,
        "foundationOffsetSeconds": TimeZone.current.secondsFromGMT(),
        "posixOffsetSeconds": Int(local.tm_gmtoff),
        "posixZone": local.tm_zone.map { String(cString: $0) } ?? ""
    ]
}
private func encoded(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
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
        } catch {
            fputs("Probe error: \(error.localizedDescription)\n", stderr)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApplication.shared.terminate(nil) }
    }
}
@main
private struct Diagnostics {
    @MainActor
    static func main() async {
        do {
            if CommandLine.arguments.dropFirst().first == "probe-child" {
                FileHandle.standardOutput.write(try encoded(snapshot()))
                return
            }
            if let path = Bundle.main.object(forInfoDictionaryKey: "TZBoxProbeOutput") as? String {
                let delegate = ProbeDelegate(output: URL(fileURLWithPath: path))
                let app = NSApplication.shared
                app.setActivationPolicy(.prohibited)
                app.delegate = delegate
                withExtendedLifetime(delegate) { app.run() }
                return
            }
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else {
                throw TZBoxError("Developer harness: native-probe APP OUTPUT TIMEZONE | chrome APP PROFILE FIXTURE_URL TIMEZONE OUTPUT")
            }
            switch command {
            case "native-probe":
                guard arguments.count == 4 else { throw TZBoxError("native-probe APP OUTPUT TIMEZONE") }
                try await nativeProbe(appURL: URL(fileURLWithPath: arguments[1]), outputURL: URL(fileURLWithPath: arguments[2]), timeZoneID: arguments[3])
            case "chrome":
                guard arguments.count == 6, let fixtureURL = URL(string: arguments[3]),
                      fixtureURL.host == "127.0.0.1" || fixtureURL.host == "localhost" else {
                    throw TZBoxError("chrome APP PROFILE FIXTURE_URL TIMEZONE OUTPUT (loopback fixture only)")
                }
                let controller = ChromeController(profileDirectory: URL(fileURLWithPath: arguments[2]))
                do {
                    try await controller.launch(applicationURL: URL(fileURLWithPath: arguments[1]), timeZoneID: arguments[4])
                    let report = try await controller.runDiagnostics(fixtureBaseURL: fixtureURL)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    try encoder.encode(report).write(to: URL(fileURLWithPath: arguments[5]), options: .atomic)
                    guard await controller.close() else { throw TZBoxError("诊断结束，但 Chrome 尚未正常退出；请手动关闭该测试实例") }
                    guard report.passed else { throw TZBoxError("诊断存在未通过或未验证项目；请查看报告") }
                } catch {
                    if controller.isActive { _ = await controller.close() }
                    throw error
                }
            default:
                throw TZBoxError("未知开发诊断命令：\(command)")
            }
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    @MainActor
    private static func nativeProbe(appURL: URL, outputURL: URL, timeZoneID: String) async throws {
        let initialZone = TimeZone.current.identifier
        let before = Date().timeIntervalSince1970
        let launcher = NativeLauncher()
        let entry = AppEntry(name: "TZBox 自有测试应用", applicationURL: appURL, backend: .native)
        try await launcher.launch(entry: entry, timeZoneID: timeZoneID)
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: outputURL.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let data = try Data(contentsOf: outputURL)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let child = result["child"] as? [String: Any],
              let timestamp = result["timestamp"] as? Double,
              let childTimestamp = child["timestamp"] as? Double,
              let zone = TimeZone(identifier: timeZoneID) else { throw TZBoxError("测试应用没有写出有效结果") }
        let after = Date().timeIntervalSince1970
        let expectedOffset = zone.secondsFromGMT(for: Date(timeIntervalSince1970: timestamp))
        var checks = [
            VerificationCheck(name: "目标应用环境变量", outcome: result["environmentTZ"] as? String == timeZoneID ? .passed : .failed, detail: "\(result["environmentTZ"] ?? "")"),
            VerificationCheck(name: "子进程环境继承", outcome: child["environmentTZ"] as? String == timeZoneID ? .passed : .failed, detail: "\(child["environmentTZ"] ?? "")"),
            VerificationCheck(name: "POSIX 本地时间", outcome: result["posixOffsetSeconds"] as? Int == expectedOffset ? .passed : .failed, detail: "\(result["posixOffsetSeconds"] ?? "") 秒"),
            VerificationCheck(name: "子进程 POSIX 本地时间", outcome: child["posixOffsetSeconds"] as? Int == expectedOffset ? .passed : .failed, detail: "\(child["posixOffsetSeconds"] ?? "") 秒"),
            VerificationCheck(name: "真实时间戳", outcome: timestamp >= before - 0.1 && timestamp <= after + 0.1 && childTimestamp >= before - 0.1 && childTimestamp <= after + 0.1 ? .passed : .failed, detail: "父进程采样区间 \(before)...\(after)"),
            VerificationCheck(name: "宿主时区保持不变", outcome: initialZone == TimeZone.current.identifier ? .passed : .failed, detail: initialZone)
        ]
        let essentialPassed = checks.allSatisfy { $0.outcome == .passed }
        checks.append(VerificationCheck(name: "Foundation 默认时区", outcome: result["foundationOffsetSeconds"] as? Int == expectedOffset ? .passed : .failed, detail: "\(result["foundationZone"] ?? "")"))
        checks.append(VerificationCheck(name: "子进程 Foundation 默认时区", outcome: child["foundationOffsetSeconds"] as? Int == expectedOffset ? .passed : .failed, detail: "\(child["foundationZone"] ?? "")"))
        let report = VerificationReport(applicationVersion: "TZBox 自有探针 0.1.0", timeZoneID: timeZoneID, checks: checks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
        let exitDeadline = Date().addingTimeInterval(5)
        while launcher.isRunning(entry.id), Date() < exitDeadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            launcher.refresh()
        }
        guard !launcher.isRunning(entry.id) else { throw TZBoxError("自有测试应用尚未退出") }
        guard essentialPassed else { throw TZBoxError("启动机制自测未通过") }
    }
}
