import AppKit
import SwiftUI
import TZBoxCore

private enum ApplicationFilter: String, CaseIterable {
    case all = "全部应用"
    case running = "运行中"
    case pending = "待重新应用"

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .running: return "play.circle"
        case .pending: return "arrow.triangle.2.circlepath"
        }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var choosingTimeZone = false
    @State private var filter = ApplicationFilter.all

    private var visibleApplications: [AppEntry] {
        model.settings.applications.filter { entry in
            switch filter {
            case .all: return true
            case .running: return model.runtime(for: entry).isRunning
            case .pending: return model.needsReapplication(entry)
            }
        }
    }

    private func count(_ filter: ApplicationFilter) -> Int {
        switch filter {
        case .all: return model.settings.applications.count
        case .running: return model.runningCount
        case .pending: return model.pendingCount
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 25) {
                header
                notices
                targetCard
                applications
                footer
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(TZStyle.canvas)
        .foregroundStyle(TZStyle.text)
        .tint(TZStyle.accent)
        .onAppear {
            model.showWindow = {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            model.refresh()
            if ProcessInfo.processInfo.environment["TZBOX_UI_SMOKE_VIEW"] == "timezone-popover" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { choosingTimeZone = true }
            }
            if ProcessInfo.processInfo.environment["TZBOX_UI_SMOKE_FILTER"] == "running" { filter = .running }
            if ProcessInfo.processInfo.environment["TZBOX_UI_SMOKE_FILTER"] == "pending" { filter = .pending }
        }
        .alert(item: $model.error) { error in
            Alert(title: Text("无法完成操作"), message: Text(error.message), dismissButton: .default(Text("知道了")))
        }
        .sheet(item: $model.detailPresentation) { presentation in
            ProxyDetailsView(model: model, presentation: presentation)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 10) {
                BrandIcon()
                VStack(alignment: .leading, spacing: 3) {
                    Text("TZBox").font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text("应用时区代理").font(.system(size: 10)).foregroundStyle(TZStyle.secondary)
                }
            }
            .padding(.top, 6)
            VStack(alignment: .leading, spacing: 8) {
                Text("工作空间").font(.system(size: 10, weight: .medium)).foregroundStyle(TZStyle.secondary)
                    .padding(.leading, 11).padding(.bottom, 3)
                ForEach(ApplicationFilter.allCases, id: \.self) { option in
                    Button { filter = option } label: {
                        HStack(spacing: 9) {
                            Image(systemName: option.icon).font(.system(size: 13)).frame(width: 16)
                            Text(option.rawValue).font(.system(size: 12, weight: filter == option ? .semibold : .regular))
                            Spacer(minLength: 4)
                            Text("\(count(option))").font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(TZStyle.secondary)
                        }
                        .foregroundStyle(filter == option ? TZStyle.accent : TZStyle.secondary)
                        .padding(.horizontal, 11).padding(.vertical, 12)
                        .background {
                            if filter == option { Color.clear.softSurface(radius: 10, recessed: true) }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == option ? .isSelected : [])
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Circle().fill(TZStyle.green).frame(width: 5, height: 5)
                    Text("系统时区保持不变").font(.system(size: 10))
                }
                Text("关闭窗口后\n可从菜单栏继续管理")
                    .font(.system(size: 10)).lineSpacing(4)
                Button { model.showDetails() } label: {
                    Label("使用说明", systemImage: "questionmark.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain).padding(.top, 4)
            }
            .foregroundStyle(TZStyle.secondary).padding(.horizontal, 9)
        }
        .padding(.horizontal, 18).padding(.vertical, 27)
        .frame(width: 188)
        .frame(maxHeight: .infinity)
        .background(TZStyle.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(TZStyle.line.opacity(0.55)).frame(width: 0.5) }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("应用时区").font(.system(size: 25, weight: .semibold))
                Text("一个目标时区，按应用分别生效。").font(.system(size: 12)).foregroundStyle(TZStyle.secondary)
            }
            Spacer()
            Button { model.selectApplications() } label: {
                Label("添加应用", systemImage: "plus")
            }
            .buttonStyle(QuietButtonStyle(prominent: true))
            .disabled(!model.settingsLoaded)
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
            HStack {
                Label("目标时区", systemImage: "globe")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(TZStyle.accent)
                Spacer()
                Button("更改时区") { choosingTimeZone = true }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!model.settingsLoaded)
                    .popover(isPresented: $choosingTimeZone, arrowEdge: .bottom) {
                        TimeZoneChooser(selected: model.settings.timeZoneID) { identifier in
                            if model.setTimeZone(identifier) { choosingTimeZone = false }
                        }
                    }
            }
            HStack(alignment: .center, spacing: 26) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.settingsLoaded ? model.settings.timeZoneID : "等待读取设置")
                        .font(.system(size: 21, weight: .medium))
                        .lineLimit(1).minimumScaleFactor(0.7).textSelection(.enabled)
                    Text("\(TimeZones.offsetLabel(for: model.settings.timeZoneID)) · 自动遵循夏令时")
                        .font(.system(size: 11)).foregroundStyle(TZStyle.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                TargetClock(identifier: model.settings.timeZoneID)
                    .opacity(model.settingsLoaded ? 1 : 0.4)
            }
            Rectangle().fill(TZStyle.line.opacity(0.8)).frame(height: 0.5)
            SystemClock()
        }
        .padding(23)
        .softSurface(radius: 18)
    }

    private var applications: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(filter.rawValue).font(.system(size: 14, weight: .semibold))
                Text("\(visibleApplications.count)").font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(TZStyle.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(TZStyle.inset, in: Capsule())
                Spacer()
                if model.pendingCount > 0 {
                    Text("\(model.pendingCount) 个待重新应用")
                        .font(.system(size: 11)).foregroundStyle(TZStyle.accent)
                } else {
                    Text("原有资料保留").font(.system(size: 11)).foregroundStyle(TZStyle.secondary)
                }
            }
            if visibleApplications.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleApplications) { entry in
                            ApplicationRow(model: model, entry: entry)
                            if entry.id != visibleApplications.last?.id {
                                Rectangle().fill(TZStyle.line.opacity(0.65)).frame(height: 0.5).padding(.horizontal, 20)
                            }
                        }
                    }
                }
                .softSurface(radius: 15)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Image(systemName: filter == .all ? "square.stack.3d.up" : filter.icon)
                .font(.system(size: 27, weight: .light))
                .foregroundStyle(TZStyle.accent)
                .frame(width: 64, height: 64)
                .softSurface(radius: 18)
                .padding(.bottom, 6)
            Text(filter == .all ? "为应用留一个不同时区" : (filter == .running ? "暂无运行中的应用" : "没有待重新应用的应用"))
                .font(.system(size: 17, weight: .medium))
            Text(filter == .all ? "添加 Mac 应用，继续使用原有资料。" : "此处显示符合筛选条件的已添加应用。")
                .font(.system(size: 12)).foregroundStyle(TZStyle.secondary)
            if filter == .all {
                Button { model.selectApplications() } label: { Label("添加第一个应用", systemImage: "plus") }
                    .buttonStyle(QuietButtonStyle()).disabled(!model.settingsLoaded).padding(.top, 5)
            } else {
                Button("查看全部应用") { filter = .all }.buttonStyle(QuietButtonStyle()).padding(.top, 5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .softSurface(radius: 15, recessed: true)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "arrow.clockwise").font(.system(size: 11))
            Text("更改时区后，需正常重启应用。兼容性取决于应用。")
                .font(.system(size: 11))
            Spacer(minLength: 0)
            Button("了解详情") { model.showDetails() }.buttonStyle(.plain)
                .font(.system(size: 11)).foregroundStyle(TZStyle.accent)
        }
        .foregroundStyle(TZStyle.secondary)
    }
}

private struct TargetClock: View {
    let identifier: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let parts = TimeZones.localTime(for: identifier, at: context.date).split(separator: " ")
            VStack(alignment: .trailing, spacing: 5) {
                Text(parts.last.map(String.init) ?? "—")
                    .font(.system(size: 38, weight: .light, design: .rounded).monospacedDigit())
                Text(parts.first.map(String.init) ?? "")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(TZStyle.secondary)
            }
        }
        .frame(minWidth: 180)
        .accessibilityLabel("目标时区当地时间")
    }
}

private struct SystemClock: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let identifier = TimeZone.current.identifier
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer").foregroundStyle(TZStyle.green)
                Text("系统").fontWeight(.medium)
                Text(identifier)
                Spacer(minLength: 8)
                Text(TimeZones.localTime(for: identifier, at: context.date)).monospacedDigit()
                Text(TimeZones.offsetLabel(for: identifier, at: context.date))
                    .padding(.leading, 4)
            }
            .font(.system(size: 11)).foregroundStyle(TZStyle.secondary)
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
                    Text(summary).font(.caption).foregroundStyle(TZStyle.secondary)
                }
                Spacer()
                actions().controlSize(.small)
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain).foregroundStyle(TZStyle.secondary)
                .accessibilityLabel(expanded ? "收起错误详情" : "展开错误详情")
            }
            if expanded {
                Text(detail).font(.caption).foregroundStyle(TZStyle.secondary).textSelection(.enabled)
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
                    .frame(width: 38, height: 38)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        if model.isBusy(entry) {
                            ProgressView().controlSize(.mini)
                        } else {
                            Circle().fill(runtime.isRunning ? TZStyle.green : TZStyle.secondary.opacity(0.65))
                                .frame(width: 5, height: 5)
                        }
                        Text(stateLabel).font(.caption).foregroundStyle(TZStyle.secondary)
                    }
                }
                .frame(minWidth: 115, maxWidth: .infinity, alignment: .leading)
                timeZoneState
                    .frame(width: 172, alignment: .leading)
                Button(model.primaryTitle(for: entry)) { model.performPrimary(entry) }
                    .buttonStyle(QuietButtonStyle())
                    .frame(minWidth: 103)
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
                .font(.caption).foregroundStyle(TZStyle.secondary)
                .padding(.leading, 57)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
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
                    Text("已应用到启动环境").font(.caption).foregroundStyle(TZStyle.secondary)
                }
            } else if runtime.isRunning {
                Text("未受管").font(.system(size: 12, weight: .medium)).foregroundStyle(TZStyle.secondary)
                Text("正常重启后应用目标时区").font(.caption).foregroundStyle(TZStyle.secondary)
            } else {
                Text("尚未应用").font(.system(size: 12)).foregroundStyle(TZStyle.secondary)
                Text("下次启动使用目标时区").font(.caption).foregroundStyle(TZStyle.secondary)
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
