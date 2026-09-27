import AppKit
import Combine
import SwiftUI
import TZBoxCore
import UniformTypeIdentifiers

struct UserFacingError: Identifiable {
    let id = UUID()
    let message: String
}

struct DetailPresentation: Identifiable {
    let id = UUID()
    let application: AppEntry?
    let report: VerificationReport?
}

@MainActor
final class AppModel: ObservableObject {
    let store: SettingsStore
    let native: NativeLauncher

    @Published private(set) var settings = TZBoxCore.Settings()
    @Published private(set) var settingsLoaded = false
    @Published private(set) var settingsFailure: String?
    @Published private var operatingEntries: Set<UUID> = []
    @Published private var operationErrors: [UUID: String] = [:]
    @Published var error: UserFacingError?
    @Published var detailPresentation: DetailPresentation?
    var showWindow: (() -> Void)?

    private enum Operation { case apply, restore, quit }
    private var lastOperations: [UUID: Operation] = [:]
    private var subscriptions: Set<AnyCancellable> = []

    init() {
        store = SettingsStore(directory: SettingsStore.defaultDirectory)
        native = NativeLauncher(sessionDirectory: SettingsStore.defaultDirectory)
        native.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &subscriptions)
        Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.refresh()
        }.store(in: &subscriptions)
        reloadSettings()
    }

    var managedCount: Int { native.sessions.values.filter { $0.isRunning }.count }
    var runningCount: Int { settings.applications.filter { runtime(for: $0).isRunning }.count }
    var pendingCount: Int { settings.applications.filter { needsReapplication($0) }.count }
    var isAnyBusy: Bool { !operatingEntries.isEmpty || !native.busyEntryIDs.isEmpty }
    var menuTitle: String {
        guard settingsLoaded else { return "TZBox · !" }
        return "\(TimeZones.offsetLabel(for: settings.timeZoneID)) · \(managedCount)"
    }

    func runtime(for entry: AppEntry) -> ApplicationRuntime { native.runtime(for: entry) }
    func status(for entry: AppEntry) -> ProxyStatus { native.status(for: entry) }
    func isBusy(_ entry: AppEntry) -> Bool {
        operatingEntries.contains(entry.id) || native.busyEntryIDs.contains(entry.id)
    }
    func needsReapplication(_ entry: AppEntry) -> Bool {
        let runtime = runtime(for: entry)
        return runtime.isRunning && runtime.isManaged && runtime.timeZoneID != settings.timeZoneID
    }
    func rowError(for entry: AppEntry) -> String? {
        operationErrors[entry.id] ?? native.errors[entry.id]
    }

    func refresh() { native.refresh(entries: settings.applications) }

    func reloadSettings() {
        guard !isAnyBusy else { return }
        do {
            settings = try store.load()
            settingsLoaded = true
            settingsFailure = nil
            refresh()
        } catch {
            settingsLoaded = false
            settingsFailure = error.localizedDescription
        }
    }

    @discardableResult
    func setTimeZone(_ identifier: String) -> Bool {
        guard settingsLoaded, TimeZones.isValid(identifier) else { return false }
        var updated = settings
        updated.timeZoneID = identifier
        // Selecting a target never changes, restarts, or relabels an existing session.
        return persist(updated)
    }

    func selectApplications() {
        guard settingsLoaded else { return }
        showWindow?()
        let panel = NSOpenPanel()
        panel.title = "添加应用"
        panel.message = "选择要使用目标时区的应用。应用继续使用原有资料。"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var updated = settings
        for url in panel.urls {
            let applicationURL = url.standardizedFileURL
            guard applicationURL.pathExtension.lowercased() == "app",
                  let bundle = Bundle(url: applicationURL), bundle.executableURL != nil else {
                error = UserFacingError(message: "请选择有效的 macOS 应用包（.app）。")
                return
            }
            guard !updated.applications.contains(where: {
                $0.applicationURL.standardizedFileURL == applicationURL
            }) else { continue }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? applicationURL.deletingPathExtension().lastPathComponent
            updated.applications.append(AppEntry(name: name, applicationURL: applicationURL, backend: .native))
        }
        guard updated != settings else { return }
        if persist(updated) { refresh() }
    }

    func primaryTitle(for entry: AppEntry) -> String {
        let runtime = runtime(for: entry)
        if runtime.isRunning {
            return runtime.isManaged && runtime.timeZoneID == settings.timeZoneID ? "打开应用" : "重启并应用"
        }
        return "应用并启动"
    }

    func performPrimary(_ entry: AppEntry) {
        guard !isBusy(entry) else { return }
        refresh()
        let runtime = runtime(for: entry)
        if runtime.isRunning && runtime.isManaged && runtime.timeZoneID == settings.timeZoneID {
            native.activate(entry: entry)
        } else {
            requestApply(entry)
        }
    }

    func activate(_ entry: AppEntry) { native.activate(entry: entry) }

    func requestApply(_ entry: AppEntry) {
        guard settingsLoaded, !isBusy(entry) else { return }
        refresh()
        let target = settings.timeZoneID
        if runtime(for: entry).isRunning {
            guard confirm(
                title: "重新启动 \(entry.name) 并应用时区？",
                message: "目标时区：\(target)\n\n请先保存未提交内容。TZBox 会请求应用正常退出，然后使用原有资料重新启动。应用中的保存或退出提示需要由你处理。",
                action: "正常重启并应用"
            ) else { return }
        }
        run(.apply, entry: entry, target: target)
    }

    func requestRestore(_ entry: AppEntry) {
        guard settingsLoaded, !isBusy(entry) else { return }
        refresh()
        guard runtime(for: entry).isRunning else { return }
        guard confirm(
            title: "恢复 \(entry.name) 的系统时区？",
            message: "请先保存未提交内容。应用将正常退出，并使用原有资料重新启动；本次启动不再设置代理时区。",
            action: "恢复并正常重启"
        ) else { return }
        run(.restore, entry: entry)
    }

    func requestQuit(_ entry: AppEntry) {
        guard !isBusy(entry) else { return }
        refresh()
        guard runtime(for: entry).isRunning else { return }
        guard confirm(
            title: "正常退出 \(entry.name)？",
            message: "请先保存未提交内容。TZBox 会请求应用正常退出；应用中的保存或退出提示需要由你处理。",
            action: "正常退出应用"
        ) else { return }
        run(.quit, entry: entry)
    }

    func retry(_ entry: AppEntry) {
        switch lastOperations[entry.id] ?? .apply {
        case .apply: requestApply(entry)
        case .restore:
            refresh()
            if runtime(for: entry).isRunning { requestRestore(entry) }
            else if settingsLoaded, !isBusy(entry) { run(.restore, entry: entry) }
        case .quit: requestQuit(entry)
        }
    }

    func remove(_ entry: AppEntry) {
        refresh()
        guard settingsLoaded, !isBusy(entry), !runtime(for: entry).isRunning else { return }
        var updated = settings
        updated.applications.removeAll { $0.id == entry.id }
        if persist(updated) {
            operationErrors.removeValue(forKey: entry.id)
            lastOperations.removeValue(forKey: entry.id)
            refresh()
        }
    }

    func showDetails(for entry: AppEntry? = nil) {
        detailPresentation = DetailPresentation(application: entry, report: entry.flatMap { store.loadReport(for: $0.id) })
    }

    func retryPersistence() {
        guard !isAnyBusy else { return }
        do { try native.retryPersistence() }
        catch { present(error, prefix: "运行记录仍未保存。") }
    }

    func recoverSessions() {
        guard !isAnyBusy else { return }
        guard confirm(
            title: "备份并恢复运行记录？",
            message: "TZBox 会保留原记录的备份，并重新识别正在运行的应用。无法确认的实例将显示为“未受管”；需要你重新应用时区后才能继续跟踪。此操作不会重启应用或修改应用资料。",
            action: "备份并恢复"
        ) else { return }
        do {
            try native.recoverSessionRecords(entries: settings.applications)
            refresh()
        } catch { present(error, prefix: "无法恢复运行记录，原记录已保留。") }
    }

    func resetSettings() {
        guard !isAnyBusy else { return }
        guard confirm(
            title: "备份并重置设置？",
            message: "原设置文件会保留为备份。目标时区与应用列表将重置，应用资料保持不变；已运行的应用不会退出。你可以重新添加应用。",
            action: "备份并重置"
        ) else { return }
        do {
            settings = try store.backupAndReset()
            settingsLoaded = true
            settingsFailure = nil
            refresh()
        } catch { present(error, prefix: "设置未能重置。") }
    }

    private func run(_ operation: Operation, entry: AppEntry, target: String? = nil) {
        guard !isBusy(entry) else { return }
        operatingEntries.insert(entry.id)
        operationErrors.removeValue(forKey: entry.id)
        lastOperations[entry.id] = operation
        Task {
            defer {
                operatingEntries.remove(entry.id)
                refresh()
            }
            do {
                switch operation {
                case .apply: try await native.apply(entry: entry, timeZoneID: target ?? settings.timeZoneID)
                case .restore: try await native.restoreSystem(entry: entry)
                case .quit: try await native.quit(entry: entry)
                }
                operationErrors.removeValue(forKey: entry.id)
            } catch {
                if native.errors[entry.id] == nil {
                    operationErrors[entry.id] = error.localizedDescription
                }
                showWindow?()
            }
        }
    }

    @discardableResult
    private func persist(_ updated: TZBoxCore.Settings) -> Bool {
        guard settingsLoaded else { return false }
        do {
            try store.save(updated)
            settings = updated
            return true
        } catch {
            present(error, prefix: "设置未能保存，当前设置保持原样。")
            return false
        }
    }

    private func confirm(title: String, message: String, action: String) -> Bool {
        showWindow?()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func present(_ error: Error, prefix: String) {
        showWindow?()
        self.error = UserFacingError(message: "\(prefix)\n\(error.localizedDescription)")
    }
}
