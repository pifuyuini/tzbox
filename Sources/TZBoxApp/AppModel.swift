import AppKit
import Combine
import SwiftUI
import TZBoxCore
import UniformTypeIdentifiers

struct UserFacingError: Identifiable {
    let id = UUID()
    let message: String
}

struct ReportPresentation: Identifiable {
    let id = UUID()
    let application: AppEntry
    let report: VerificationReport?
    let isCurrentSession: Bool
}

@MainActor
final class AppModel: ObservableObject {
    let store: SettingsStore
    let native: NativeLauncher
    let chrome: ChromeController

    @Published private(set) var settings = TZBoxCore.Settings()
    @Published private(set) var settingsLoaded = false
    @Published private(set) var settingsFailure: String?
    @Published private(set) var busyEntries: Set<UUID> = []
    @Published var error: UserFacingError?
    @Published var reportPresentation: ReportPresentation?
    var showWindow: (() -> Void)?

    private var subscriptions: Set<AnyCancellable> = []

    init() {
        store = SettingsStore(directory: SettingsStore.defaultDirectory)
        native = NativeLauncher(sessionDirectory: SettingsStore.defaultDirectory)
        chrome = ChromeController(profileDirectory: store.chromeProfileDirectory)
        native.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &subscriptions)
        chrome.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &subscriptions)
        chrome.$report.dropFirst().sink { [weak self] report in
            guard let self, let report, self.settingsLoaded,
                  let entry = self.chromeEntry else { return }
            do {
                try self.store.saveReport(report, for: entry.id)
            } catch {
                self.present(error, prefix: "验证已完成，但记录保存失败。")
            }
        }.store(in: &subscriptions)
        Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.native.refresh()
        }.store(in: &subscriptions)
        reloadSettings()
    }

    var chromeEntry: AppEntry? { settings.applications.first { $0.backend == .chrome } }
    var nativeEntries: [AppEntry] { settings.applications.filter { $0.backend == .native } }
    var hasPendingNativeLaunch: Bool {
        nativeEntries.contains { busyEntries.contains($0.id) }
    }
    var runningCount: Int {
        native.sessions.values.filter { $0.isRunning }.count + (chrome.isActive ? 1 : 0)
    }
    var timeZoneLocked: Bool {
        chrome.isActive || native.hasRunningApplications || native.persistenceError != nil || !busyEntries.isEmpty
    }
    var menuTitle: String { "TZBox · \(runningCount)" }

    func reloadSettings() {
        do {
            settings = try store.load()
            settingsFailure = nil
            settingsLoaded = true
        } catch {
            settingsFailure = error.localizedDescription
            settingsLoaded = false
        }
    }

    func setTimeZone(_ identifier: String) {
        native.refresh()
        guard settingsLoaded, !timeZoneLocked, TimeZones.isValid(identifier) else { return }
        var updated = settings
        updated.timeZoneID = identifier
        persist(updated)
    }

    func selectApplication(for requestedBackend: AppBackend) {
        guard settingsLoaded else { return }
        let panel = NSOpenPanel()
        panel.title = requestedBackend == .chrome ? "选择 Google Chrome" : "添加应用"
        panel.message = requestedBackend == .chrome
            ? "请选择 Google Chrome.app。TZBox 将使用独立资料保存登录状态。"
            : "选择要通过 TZBox 启动的应用。是否支持目标时区需要单独验证。"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
              bundle.executableURL != nil else {
            error = UserFacingError(message: "请选择有效的 macOS 应用包（.app）。")
            return
        }
        let backend: AppBackend = identifier == "com.google.Chrome" ? .chrome : .native
        if requestedBackend == .chrome && backend != .chrome {
            error = UserFacingError(message: "Chrome 专用入口仅支持 Google Chrome，请重新选择 Google Chrome.app。")
            return
        }
        if settings.applications.contains(where: { $0.applicationURL.standardizedFileURL == url.standardizedFileURL }) {
            error = UserFacingError(message: "此应用已在列表中。")
            return
        }
        if backend == .chrome && chromeEntry != nil {
            error = UserFacingError(message: "首版只支持一份 Chrome 配置。如需更换 Chrome，请先退出受控实例并移除原条目。")
            return
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        var updated = settings
        updated.applications.append(AppEntry(name: name, applicationURL: url, backend: backend))
        persist(updated)
    }

    func remove(_ entry: AppEntry) {
        native.refresh()
        guard settingsLoaded, !isBusy(entry), !isRunning(entry) else { return }
        var updated = settings
        updated.applications.removeAll { $0.id == entry.id }
        persist(updated)
    }

    func isRunning(_ entry: AppEntry) -> Bool {
        entry.backend == .chrome ? chrome.isActive : native.isRunning(entry.id)
    }

    func isBusy(_ entry: AppEntry) -> Bool { busyEntries.contains(entry.id) }

    func activate(_ entry: AppEntry) {
        if entry.backend == .chrome { chrome.activate() }
        else { native.activate(entry.id) }
    }

    func launch(_ entry: AppEntry) {
        guard settingsLoaded, !isBusy(entry), !isRunning(entry) else { return }
        busyEntries.insert(entry.id)
        let target = settings.timeZoneID
        Task {
            defer { busyEntries.remove(entry.id) }
            do {
                if entry.backend == .chrome {
                    try await chrome.launch(applicationURL: entry.applicationURL, timeZoneID: target)
                } else {
                    try await native.launch(entry: entry, timeZoneID: target)
                }
            } catch {
                present(error, prefix: "无法启动 \(entry.name)。")
            }
        }
    }

    func checkChrome() {
        guard let entry = chromeEntry, !isBusy(entry), chrome.state == .running else { return }
        busyEntries.insert(entry.id)
        Task {
            defer { busyEntries.remove(entry.id) }
            do {
                let report = try await chrome.check()
                reportPresentation = ReportPresentation(application: entry, report: report, isCurrentSession: true)
            } catch { present(error, prefix: "时区检查未完成。") }
        }
    }

    func reconnectChrome() {
        guard let entry = chromeEntry, chrome.isActive, !isBusy(entry) else { return }
        busyEntries.insert(entry.id)
        Task {
            defer { busyEntries.remove(entry.id) }
            do { try await chrome.reconnect() }
            catch { present(error, prefix: "无法恢复 Chrome 控制。") }
        }
    }

    func closeChrome() {
        guard let entry = chromeEntry, !isBusy(entry) else { return }
        busyEntries.insert(entry.id)
        Task {
            defer { busyEntries.remove(entry.id) }
            if !(await chrome.close()) {
                error = UserFacingError(message: "Chrome 尚未正常退出。请处理 Chrome 中的提示或手动关闭受控实例后重试。")
            }
        }
    }

    func showReport(for entry: AppEntry) {
        let current = entry.backend == .chrome && chrome.state == .running ? chrome.report : nil
        let report = current ?? store.loadReport(for: entry.id)
        reportPresentation = ReportPresentation(application: entry, report: report, isCurrentSession: current != nil)
    }

    private func persist(_ updated: TZBoxCore.Settings) {
        guard settingsLoaded else { return }
        do {
            try store.save(updated)
            settings = updated
        } catch { present(error, prefix: "配置未保存，当前设置保持原样。") }
    }

    private func present(_ error: Error, prefix: String) {
        showWindow?()
        self.error = UserFacingError(message: "\(prefix)\n\(error.localizedDescription)")
    }
}
