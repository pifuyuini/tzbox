import AppKit
import SwiftUI
import TZBoxCore

struct MainView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var choosingTimeZone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            notices
            targetCard
            applications
            footer
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(minWidth: 860, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.showWindow = {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            model.refresh()
            if ProcessInfo.processInfo.environment["TZBOX_UI_SMOKE_VIEW"] == "timezone-popover" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { choosingTimeZone = true }
            }
        }
        .alert(item: $model.error) { error in
            Alert(title: Text("无法完成操作"), message: Text(error.message), dismissButton: .default(Text("知道了")))
        }
        .sheet(item: $model.detailPresentation) { presentation in
            ProxyDetailsView(model: model, presentation: presentation)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("TZBox").font(.system(size: 25, weight: .semibold))
                Text("应用时区代理").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.showDetails() } label: {
                Image(systemName: "info.circle").font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("了解时区代理")
            .accessibilityLabel("了解时区代理")
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let failure = model.settingsFailure {
            RecoveryNotice(title: "设置无法读取", summary: "原设置已保留，可重试读取或备份后重置。", detail: failure) {
                Button("重新读取") { model.reloadSettings() }
                Button("备份并重置…") { model.resetSettings() }
            }
        }
        if let failure = model.native.persistenceError {
            RecoveryNotice(title: "运行记录需要处理", summary: "应用仍保持当前状态。修复记录后可继续管理。", detail: failure) {
                Button("重试保存") { model.retryPersistence() }
                Button("备份并恢复…") { model.recoverSessions() }
            }
            .disabled(model.isAnyBusy)
        }
    }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("目标时区").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Text(model.settingsLoaded ? model.settings.timeZoneID : "等待读取设置")
                            .font(.system(size: 24, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.75)
                            .textSelection(.enabled)
                        Button("更改…") { choosingTimeZone = true }
                            .disabled(!model.settingsLoaded)
                            .popover(isPresented: $choosingTimeZone, arrowEdge: .bottom) {
                                TimeZoneChooser(selected: model.settings.timeZoneID) { identifier in
                                    if model.setTimeZone(identifier) { choosingTimeZone = false }
                                }
                            }
                    }
                    Text("\(TimeZones.offsetLabel(for: model.settings.timeZoneID)) · 按当地规则处理夏令时")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                TargetClock(identifier: model.settings.timeZoneID)
                    .opacity(model.settingsLoaded ? 1 : 0.35)
            }
            Divider()
            SystemClock()
        }
        .padding(22)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
    }

    private var applications: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Text("应用").font(.headline)
                Text("\(model.settings.applications.count)")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.055), in: Capsule())
                if model.pendingCount > 0 {
                    Text("\(model.pendingCount) 个待重新应用")
                        .font(.caption).foregroundStyle(.orange)
                } else if model.runningCount > 0 {
                    Text("\(model.runningCount) 个运行中")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.selectApplications() } label: {
                    Label("添加应用…", systemImage: "plus")
                }
                .disabled(!model.settingsLoaded)
            }
            if model.settings.applications.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.settings.applications) { entry in
                            ApplicationRow(model: model, entry: entry)
                            if entry.id != model.settings.applications.last?.id {
                                Divider().padding(.leading, 76)
                            }
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Image(systemName: "app.badge")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Text("为应用选择另一时区").font(.title3.weight(.semibold))
            Text("添加 Mac 应用，使用原有资料启动。")
                .font(.callout).foregroundStyle(.secondary)
            Button { model.selectApplications() } label: {
                Label("添加第一个应用…", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.settingsLoaded)
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5))
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("更改应用时区需要正常重启，原有资料保留。兼容性取决于应用。")
                Text("关闭窗口后，TZBox 继续在菜单栏运行。")
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button("了解详情") { model.showDetails() }.buttonStyle(.link)
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

private struct TargetClock: View {
    let identifier: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let parts = TimeZones.localTime(for: identifier, at: context.date).split(separator: " ")
            VStack(alignment: .trailing, spacing: 6) {
                Text(parts.last.map(String.init) ?? "—")
                    .font(.system(size: 33, weight: .light, design: .rounded).monospacedDigit())
                Text(parts.first.map(String.init) ?? "")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 155)
        .accessibilityLabel("目标时区当地时间")
    }
}

private struct SystemClock: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let identifier = TimeZone.current.identifier
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                Text("系统").fontWeight(.medium)
                Text(identifier)
                Spacer()
                Text(TimeZones.localTime(for: identifier, at: context.date))
                    .monospacedDigit()
                Text("·")
                Text(TimeZones.offsetLabel(for: identifier, at: context.date))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct RecoveryNotice<Actions: View>: View {
    let title: String
    let summary: String
    let detail: String
    @ViewBuilder let actions: () -> Actions
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                actions().controlSize(.small)
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(expanded ? "收起错误详情" : "展开错误详情")
            }
            if expanded {
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct ApplicationRow: View {
    @ObservedObject var model: AppModel
    let entry: AppEntry

    private var runtime: ApplicationRuntime { model.runtime(for: entry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 13) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: entry.applicationURL.path))
                    .resizable().interpolation(.high)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        if model.isBusy(entry) {
                            ProgressView().controlSize(.mini)
                        } else {
                            Circle().fill(runtime.isRunning ? Color.green : Color.secondary.opacity(0.45))
                                .frame(width: 5, height: 5)
                        }
                        Text(stateLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                timeZoneState
                    .frame(width: 230, alignment: .leading)
                Button(model.primaryTitle(for: entry)) { model.performPrimary(entry) }
                    .frame(minWidth: 102)
                    .disabled(!model.settingsLoaded || model.isBusy(entry))
                rowMenu
            }
            if let failure = model.rowError(for: entry) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(failure).lineLimit(2).help(failure).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("重试") { model.retry(entry) }
                        .disabled(model.isBusy(entry) || !model.settingsLoaded)
                    Button("详情") { model.showDetails(for: entry) }.buttonStyle(.link)
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 57)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 17)
    }

    @ViewBuilder
    private var timeZoneState: some View {
        VStack(alignment: .leading, spacing: 5) {
            if runtime.isRunning && runtime.isManaged, let actual = runtime.timeZoneID {
                Text(actual).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                    .help("本次启动时区：\(actual)")
                if model.needsReapplication(entry) {
                    Label("待重新应用", systemImage: "arrow.clockwise")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text("已应用到启动环境").font(.caption).foregroundStyle(.secondary)
                }
            } else if runtime.isRunning {
                Text("未受管").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Text("正常重启后应用目标时区").font(.caption).foregroundStyle(.tertiary)
            } else {
                Text("尚未应用").font(.callout).foregroundStyle(.secondary)
                Text("下次启动使用目标时区").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var stateLabel: String {
        switch model.status(for: entry) {
        case .starting: return "正在启动…"
        case .stopping: return "等待正常退出…"
        case .runningManaged, .runningUnmanaged: return "运行中"
        case .failed: return "未运行 · 上次操作未完成"
        case .stopped: return model.isBusy(entry) ? "正在准备…" : "未运行"
        }
    }

    private var rowMenu: some View {
        Menu {
            Button("打开应用") { model.activate(entry) }
                .disabled(!runtime.isRunning || model.isBusy(entry))
            Button("重新应用目标时区…") { model.requestApply(entry) }
                .disabled(!model.settingsLoaded || model.isBusy(entry))
            Button("恢复系统时区并重启…") { model.requestRestore(entry) }
                .disabled(!model.settingsLoaded || !runtime.isRunning || model.isBusy(entry))
            Button("正常退出应用…") { model.requestQuit(entry) }
                .disabled(!runtime.isRunning || model.isBusy(entry))
            Divider()
            Button("应用详情与验证记录") { model.showDetails(for: entry) }
            Button("移除列表", role: .destructive) { model.remove(entry) }
                .disabled(!model.settingsLoaded || runtime.isRunning || model.isBusy(entry))
                .help("请先正常退出应用，再从列表中移除。")
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 16))
                .frame(width: 20, height: 24)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("\(entry.name) 的更多操作")
        .accessibilityLabel("\(entry.name) 的更多操作")
    }
}
