import AppKit
import SwiftUI
import TZBoxCore

@main
@MainActor
struct TZBoxApp: App {
    @NSApplicationDelegateAdaptor(TZBoxApplicationDelegate.self) private var delegate
    @StateObject private var model: AppModel

    init() {
        // Override only this process for reproducible own-window visual QA.
        if ProcessInfo.processInfo.environment["TZBOX_UI_SMOKE_OUTPUT"] != nil {
            let appearance = ProcessInfo.processInfo.environment["TZBOX_UI_SMOKE_APPEARANCE"]
            if appearance == "dark" { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
            if appearance == "light" { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
            if appearance == "contrast" { NSApplication.shared.appearance = NSAppearance(named: .accessibilityHighContrastAqua) }
        }
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        TZBoxApplicationDelegate.model = model
    }

    var body: some Scene {
        Window("TZBox", id: "main") {
            MainView(model: model)
                .background(SmokeWindowMarker(identifier: "TZBoxMainWindow"))
        }
        .defaultSize(width: 1080, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加应用…") { model.selectApplications() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(!model.settingsLoaded)
            }
        }

        MenuBarExtra(model.menuTitle, systemImage: "globe") {
            TZBoxMenu(model: model)
        }
    }
}

@MainActor
final class TZBoxApplicationDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let path = ProcessInfo.processInfo.environment["TZBOX_UI_SMOKE_OUTPUT"], !path.isEmpty else { return }
        let captureChooser = ProcessInfo.processInfo.environment["TZBOX_UI_SMOKE_VIEW"] == "timezone-popover"
        // QA captures only a content view owned by this process, never the display.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            do {
                let identifier = captureChooser ? "TZBoxTimeZoneChooser" : "TZBoxMainWindow"
                guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier && $0.isVisible }),
                      let view = window.contentView else {
                    throw TZBoxError("自有窗口尚未显示，无法生成 UI 验收图片。")
                }
                if !captureChooser && ProcessInfo.processInfo.environment["TZBOX_UI_SMOKE_COMPACT"] == "1" {
                    window.setContentSize(NSSize(width: 980, height: 680))
                }
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw TZBoxError("无法分配窗口验收图片。")
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                // Native popover materials are outside the cached content view.
                // Flatten only the QA image onto the window's resolved background.
                guard let opaque = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ), let context = NSGraphicsContext(bitmapImageRep: opaque) else {
                    throw TZBoxError("无法分配不透明窗口验收图片。")
                }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                let bounds = NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    NSBezierPath.fill(bounds)
                    NSImage(cgImage: bitmap.cgImage!, size: bounds.size).draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
                }
                NSGraphicsContext.restoreGraphicsState()
                guard let png = opaque.representation(using: .png, properties: [:]) else {
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
        if model.isAnyBusy {
            model.showWindow?()
            model.error = UserFacingError(message: "应用正在启动、重启或退出。请等待当前操作与运行记录保存完成后，再退出 TZBox。")
            return .terminateCancel
        }
        model.refresh()
        if model.native.persistenceError != nil && model.managedCount > 0 {
            model.showWindow?()
            model.error = UserFacingError(message: "仍有受管应用在运行，但运行记录尚未保存。请在窗口中重试保存，或先正常退出受管应用，再退出 TZBox。")
            return .terminateCancel
        }
        // The TZ environment belongs to the launched process; closing TZBox does
        // not close applications or undo a successfully applied launch environment.
        return .terminateNow
    }
}

private struct TZBoxMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.settingsLoaded ? model.settings.timeZoneID : "设置需要恢复")
        Text("\(model.managedCount) 个受管应用\(model.pendingCount > 0 ? " · \(model.pendingCount) 个待重新应用" : "")")
        Divider()
        Button("打开 TZBox") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("0", modifiers: .command)
        Button("添加应用…") { model.selectApplications() }.disabled(!model.settingsLoaded)
        if !model.settings.applications.isEmpty {
            Divider()
            ForEach(model.settings.applications) { entry in
                applicationMenu(entry)
            }
        }
        Divider()
        Button("退出 TZBox") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
            .disabled(model.isAnyBusy)
    }

    private func applicationMenu(_ entry: AppEntry) -> some View {
        let runtime = model.runtime(for: entry)
        return Menu {
            Text(runtime.isRunning ? (runtime.isManaged ? "本次启动：\(runtime.timeZoneID ?? "未知")" : "运行中 · 时区待确认") : "未运行")
            if model.needsReapplication(entry) { Text("待重新应用目标时区") }
            if model.rowError(for: entry) != nil { Text("上次操作未完成，请打开窗口查看") }
            Button(model.primaryTitle(for: entry)) { model.performPrimary(entry) }
                .disabled(!model.settingsLoaded || model.isBusy(entry))
            if runtime.isRunning {
                Button("打开应用") { model.activate(entry) }.disabled(model.isBusy(entry))
                Button("恢复系统时区并重启…") { model.requestRestore(entry) }
                    .disabled(!model.settingsLoaded || model.isBusy(entry))
                Button("正常退出应用…") { model.requestQuit(entry) }.disabled(model.isBusy(entry))
            }
        } label: {
            Label {
                Text(entry.name)
            } icon: {
                Image(nsImage: NSWorkspace.shared.icon(forFile: entry.applicationURL.path))
            }
        }
    }
}

/// Identifies a window through an invisible view inside its own hierarchy. The
/// smoke tool can then choose the main content or the native time-zone popover.
struct SmokeWindowMarker: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> WindowMarkerView {
        WindowMarkerView(identifier: identifier)
    }

    func updateNSView(_ nsView: WindowMarkerView, context: Context) {}
}

final class WindowMarkerView: NSView {
    private let marker: String

    init(identifier: String) {
        marker = identifier
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.identifier = NSUserInterfaceItemIdentifier(marker)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
