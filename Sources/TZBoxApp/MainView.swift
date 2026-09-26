import AppKit
import SwiftUI
import TZBoxCore

struct MainView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var choosingTimeZone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("应用时区").font(.largeTitle.weight(.semibold))
                    Text("以另一时区显示同一个真实时刻。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("系统时区保持不变", systemImage: "clock.badge.checkmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 9)
            }

            if let failure = model.settingsFailure {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("无法读取配置", systemImage: "exclamationmark.triangle")
                            .font(.headline).foregroundStyle(.orange)
                        Text(failure).font(.callout).textSelection(.enabled)
                        Text("原配置文件保留不变。修复后可重新加载，加载成功前无法保存或启动应用。")
                            .foregroundStyle(.secondary)
                        Button("重新加载配置") { model.reloadSettings() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }

            if let failure = model.native.persistenceError {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("运行记录异常", systemImage: "exclamationmark.triangle")
                            .font(.headline).foregroundStyle(.orange)
                        Text(failure).font(.callout).textSelection(.enabled)
                        Text("暂时无法完整确认受控应用状态，已锁定目标时区。请修复运行记录后重新打开 TZBox。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }

            timeZonePanel
                .disabled(!model.settingsLoaded)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    chromeSection
                    nativeSection
                    VStack(alignment: .leading, spacing: 5) {
                        Text("兼容性说明").font(.subheadline.weight(.semibold))
                        Text("Chrome 的检查仅覆盖记录中列出的网页环境。普通应用是否采用目标时区取决于应用实现，启动成功不等于时区已生效。网站账号、服务器以及发送给模型的时间需单独验证。")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("关闭此窗口后，TZBox 会继续在菜单栏运行。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 3)
                }
                .padding(.bottom, 4)
            }
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 590)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.showWindow = {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .alert(item: $model.error) { error in
            Alert(title: Text("无法完成操作"), message: Text(error.message), dismissButton: .default(Text("知道了")))
        }
        .sheet(item: $model.reportPresentation) { presentation in
            VerificationReportView(presentation: presentation)
        }
    }

    private var timeZonePanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 20) {
                    Image(systemName: "globe.asia.australia.fill")
                        .font(.system(size: 34)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("统一目标时区").font(.caption).foregroundStyle(.secondary)
                        Text(model.settings.timeZoneID).font(.title2.weight(.medium)).textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(TimeZones.localTime(for: model.settings.timeZoneID, at: context.date))
                                .font(.title3.monospacedDigit())
                            Text(TimeZones.offsetLabel(for: model.settings.timeZoneID, at: context.date))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("更改时区") { choosingTimeZone = true }
                        .disabled(model.timeZoneLocked)
                        .popover(isPresented: $choosingTimeZone) {
                            TimeZoneChooser(selected: model.settings.timeZoneID) { identifier in
                                model.setTimeZone(identifier)
                                choosingTimeZone = false
                            }
                        }
                }
                if model.timeZoneLocked {
                    Label("请先退出受控实例，再更改目标时区。", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
    }

    private var chromeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Chrome").font(.headline)
                Spacer()
                Text("独立资料 · 保留登录状态").font(.caption).foregroundStyle(.secondary)
            }
            GroupBox {
                if let entry = model.chromeEntry {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            applicationIcon(entry)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.name).font(.headline)
                                Label(chromeStatus, systemImage: chromeStatusIcon)
                                    .font(.callout).foregroundStyle(chromeStatusColor)
                            }
                            Spacer()
                            if model.isBusy(entry) || model.chrome.state == .starting || model.chrome.state == .stopping {
                                ProgressView().controlSize(.small)
                            }
                            if model.chrome.isActive {
                                Button("显示") { model.activate(entry) }
                                    .disabled(model.chrome.state == .starting || model.chrome.state == .stopping)
                            } else {
                                Button("启动") { model.launch(entry) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!model.settingsLoaded || model.isBusy(entry))
                            }
                            rowMenu(entry)
                        }
                        if !model.chrome.message.isEmpty {
                            Text(model.chrome.message).font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        HStack(spacing: 10) {
                            Button("检查时区") { model.checkChrome() }
                                .disabled(model.chrome.state != .running || model.isBusy(entry))
                            if model.chrome.state == .interrupted || (model.chrome.state == .failed && model.chrome.isActive) {
                                Button("恢复控制") { model.reconnectChrome() }
                                    .disabled(model.isBusy(entry))
                            }
                            Button("查看验证记录") { model.showReport(for: entry) }
                            Spacer()
                            if model.chrome.isActive {
                                Button("正常关闭 Chrome") { model.closeChrome() }
                                    .disabled(model.isBusy(entry) || model.chrome.state == .starting || model.chrome.state == .stopping)
                            }
                        }
                    }
                    .padding(10)
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "globe").font(.system(size: 28)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("选择 Google Chrome").font(.headline)
                            Text("首次使用独立资料，需要重新登录网站。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("选择 Chrome…") { model.selectApplication(for: .chrome) }
                            .disabled(!model.settingsLoaded)
                    }
                    .padding(10)
                }
            }
        }
    }

    private var nativeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("其他应用").font(.headline)
                Spacer()
                Button { model.selectApplication(for: .native) } label: {
                    Label("添加应用…", systemImage: "plus")
                }
                .disabled(!model.settingsLoaded)
            }
            if model.nativeEntries.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("尚未添加应用").font(.subheadline.weight(.medium))
                        Text("选择 .app 后即可尝试以目标时区启动。普通应用使用自己的现有资料。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            } else {
                ForEach(model.nativeEntries) { entry in
                    GroupBox {
                        HStack(spacing: 12) {
                            applicationIcon(entry)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.name).font(.headline)
                                Text(model.native.isRunning(entry.id) ? "已启动 · 时区效果未验证" : "未运行 · 时区效果未验证")
                                    .font(.callout).foregroundStyle(.secondary)
                                if let session = model.native.sessions[entry.id], session.isRunning {
                                    Text("启动时区：\(session.timeZoneID)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if model.isBusy(entry) { ProgressView().controlSize(.small) }
                            if model.native.isRunning(entry.id) {
                                Button("显示") { model.activate(entry) }
                            } else {
                                Button("启动") { model.launch(entry) }
                                    .disabled(!model.settingsLoaded || model.isBusy(entry))
                            }
                            rowMenu(entry)
                        }
                        .padding(10)
                    }
                }
            }
        }
    }

    private func applicationIcon(_ entry: AppEntry) -> some View {
        Image(systemName: entry.backend == .chrome ? "globe" : "app.dashed")
            .font(.system(size: 28)).foregroundStyle(.secondary)
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)
    }

    private func rowMenu(_ entry: AppEntry) -> some View {
        Menu {
            Button("查看验证记录") { model.showReport(for: entry) }
            Button("从列表移除", role: .destructive) { model.remove(entry) }
                .disabled(model.isRunning(entry) || model.isBusy(entry) || !model.settingsLoaded)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("应用操作")
        .accessibilityLabel("\(entry.name) 操作")
    }

    private var chromeStatus: String {
        switch model.chrome.state {
        case .stopped: return "未运行"
        case .starting: return "正在启动并设置时区…"
        case .running: return "正在运行 · 验证范围请查看记录"
        case .interrupted: return "控制中断 · 时区效果待重新确认"
        case .stopping: return "正在正常关闭…"
        case .failed: return "操作失败 · 时区效果未确认"
        }
    }

    private var chromeStatusIcon: String {
        switch model.chrome.state {
        case .interrupted, .failed: return "exclamationmark.triangle"
        case .running: return "play.circle"
        default: return "circle.dotted"
        }
    }

    private var chromeStatusColor: Color {
        model.chrome.state == .interrupted || model.chrome.state == .failed ? .orange : .secondary
    }
}

private struct TimeZoneChooser: View {
    let selected: String
    let choose: (String) -> Void
    @State private var query = ""

    private var filtered: [String] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var matches = TimeZones.identifiers.filter { value.isEmpty || $0.localizedCaseInsensitiveContains(value) }
        if !value.isEmpty, TimeZones.isValid(value), !matches.contains(value) {
            matches.insert(value, at: 0)
        }
        return matches
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择目标时区").font(.headline)
            TextField("搜索城市或 IANA ID，如 Tokyo", text: $query)
                .textFieldStyle(.roundedBorder)
            if filtered.isEmpty {
                Text("未找到匹配时区").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered, id: \.self) { identifier in
                    Button { choose(identifier) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(identifier).foregroundStyle(.primary)
                                Text(TimeZones.offsetLabel(for: identifier))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if identifier == selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                }
            }
            Text("时区按当地规则自动处理夏令时。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 390, height: 420)
    }
}

private struct VerificationReportView: View {
    let presentation: ReportPresentation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(presentation.application.name) · 验证记录").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if let report = presentation.report {
                VStack(alignment: .leading, spacing: 5) {
                    Text(presentation.isCurrentSession ? "本次会话检查结果" : "历史记录，不代表当前会话状态")
                        .font(.headline)
                    Text("应用版本：\(report.applicationVersion)")
                    Text("目标时区：\(report.timeZoneID)")
                    Text("检查时间：\(report.checkedAt.formatted(date: .abbreviated, time: .standard))")
                }
                .font(.callout)
                .textSelection(.enabled)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(report.checks, id: \.name) { check in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: icon(check.outcome))
                                    .foregroundStyle(color(check.outcome))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(check.name) · \(label(check.outcome))").font(.headline)
                                    Text(check.detail).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Text("结果仅适用于所记录的版本与检查项目，不代表所有页面、插件或模型请求都已采用目标时区。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Label("尚无验证记录", systemImage: "questionmark.circle").font(.headline)
                    Text("成功启动只说明应用进程已运行。普通应用是否采用目标时区，需要检查其实际时间显示或请求数据。")
                    Text("发送给模型的日期、时间和时区，必须通过合成请求及本机模拟接口验证；模型回答不能作为证据。")
                }
                .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 650, height: 500)
    }

    private func label(_ outcome: VerificationOutcome) -> String {
        switch outcome {
        case .passed: return "通过"
        case .failed: return "未通过"
        case .unverified: return "未验证"
        }
    }

    private func icon(_ outcome: VerificationOutcome) -> String {
        switch outcome {
        case .passed: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .unverified: return "questionmark.circle"
        }
    }

    private func color(_ outcome: VerificationOutcome) -> Color {
        switch outcome {
        case .passed: return .green
        case .failed: return .orange
        case .unverified: return .secondary
        }
    }
}
