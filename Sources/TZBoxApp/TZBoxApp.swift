import AppKit
import SwiftUI
import TZBoxCore

@main
@MainActor
struct TZBoxApp: App {
    @NSApplicationDelegateAdaptor(TZBoxApplicationDelegate.self) private var delegate
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        TZBoxApplicationDelegate.model = model
    }

    var body: some Scene {
        Window("TZBox", id: "main") {
            MainView(model: model)
        }
        .defaultSize(width: 880, height: 670)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra(model.menuTitle, systemImage: "globe") {
            TZBoxMenu(model: model)
        }
    }
}

@MainActor
final class TZBoxApplicationDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let path = ProcessInfo.processInfo.environment["TZBOX_UI_SMOKE_OUTPUT"], !path.isEmpty else { return }
        // Development-only QA captures this app's own content view, never the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            do {
                guard let window = NSApp.windows.first(where: { $0.title == "TZBox" && $0.isVisible }),
                      let view = window.contentView else {
                    throw TZBoxError("自有窗口尚未显示，无法生成 UI 验收图片。")
                }
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw TZBoxError("无法分配窗口验收图片。")
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw TZBoxError("无法编码窗口验收图片。")
                }
                try png.write(to: URL(fileURLWithPath: path), options: .atomic)
                NSApp.terminate(nil)
            } catch {
                FileHandle.standardError.write(Data("UI_SMOKE_FAILED: \(error.localizedDescription)\n".utf8))
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.model?.showWindow?()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        guard !terminationPending else { return .terminateCancel }
        if model.hasPendingNativeLaunch {
            model.showWindow?()
            model.error = UserFacingError(message: "普通应用正在启动，请等待启动和运行记录保存完成后再退出 TZBox。")
            return .terminateCancel
        }
        model.native.refresh()
        if model.native.persistenceError != nil && model.native.hasRunningApplications {
            model.showWindow?()
            model.error = UserFacingError(message: "运行记录未能保存。请先正常退出由 TZBox 启动的普通应用，再退出 TZBox，以免遗失仍在运行的会话记录。")
            return .terminateCancel
        }
        if model.chrome.state == .starting || model.chrome.state == .stopping
            || (model.chromeEntry.map { model.isBusy($0) && !model.chrome.isActive } ?? false) {
            model.showWindow?()
            model.error = UserFacingError(message: "Chrome 正在启动或退出，请等待当前操作完成后再退出 TZBox。")
            return .terminateCancel
        }
        guard model.chrome.isActive else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "关闭受控 Chrome 后退出 TZBox？"
        alert.informativeText = "Chrome 仍在使用目标时区。退出前需要正常关闭这一实例；其他普通应用可以继续运行。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "取消退出")
        alert.addButton(withTitle: "正常关闭 Chrome 后退出")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        terminationPending = true
        Task { @MainActor in
            let closed = await model.chrome.close()
            terminationPending = false
            sender.reply(toApplicationShouldTerminate: closed)
            if !closed {
                model.showWindow?()
                model.error = UserFacingError(message: "Chrome 尚未正常关闭，TZBox 已保留运行。请处理 Chrome 中的提示或手动关闭受控实例后再退出。")
            }
        }
        return .terminateLater
    }
}

private struct TZBoxMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.settingsLoaded ? model.settings.timeZoneID : "配置加载失败")
        Text("\(model.runningCount) 个受控应用正在运行")
        if model.chrome.state == .interrupted {
            Text("Chrome 控制中断")
        }
        Divider()
        Button("打开 TZBox") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        if let entry = model.chromeEntry {
            if model.chrome.isActive {
                Button("显示 Chrome") { model.activate(entry) }
                Button("检查 Chrome 时区") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                    model.checkChrome()
                }
                    .disabled(model.chrome.state != .running || model.isBusy(entry))
            } else {
                Button("启动 Chrome") { model.launch(entry) }
                    .disabled(!model.settingsLoaded || model.isBusy(entry))
            }
        }
        Divider()
        Button("退出 TZBox") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
