import AppKit
import SwiftUI
import TZBoxCore

struct ProxyDetailsView: View {
    @ObservedObject var model: AppModel
    let presentation: DetailPresentation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                if let entry = presentation.application {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.applicationURL.path))
                        .resizable().frame(width: 38, height: 38).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.application?.name ?? "关于时区代理").font(.title2.weight(.semibold))
                    if presentation.application != nil {
                        Text("应用详情与验证记录").font(.caption).foregroundStyle(TZStyle.secondary)
                    }
                }
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.defaultAction)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let entry = presentation.application {
                        applicationDetails(entry)
                        Divider()
                        reportDetails
                        Divider()
                    }
                    explanation
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(28)
        .frame(width: 660, height: 550)
        .background(TZStyle.canvas)
        .foregroundStyle(TZStyle.text)
        .tint(TZStyle.accent)
    }

    private func applicationDetails(_ entry: AppEntry) -> some View {
        let runtime = model.runtime(for: entry)
        return VStack(alignment: .leading, spacing: 12) {
            LabeledContent("状态", value: runtime.isRunning ? (runtime.isManaged ? "运行中 · 受管" : "运行中 · 未受管") : "未运行")
            if runtime.isManaged, let timeZone = runtime.timeZoneID {
                LabeledContent("本次启动时区", value: timeZone)
            }
            LabeledContent("当前目标时区", value: model.settings.timeZoneID)
            if let version = runtime.applicationVersion {
                LabeledContent("版本", value: version)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("应用位置").foregroundStyle(TZStyle.secondary)
                Text(entry.applicationURL.path).font(.caption).textSelection(.enabled)
            }
            if let error = model.rowError(for: entry) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("上次操作未完成", systemImage: "exclamationmark.circle").fontWeight(.medium)
                    Text(error).textSelection(.enabled)
                }
                .font(.callout).foregroundStyle(.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private var reportDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("验证记录").font(.headline)
            if let report = presentation.report {
                Text("历史检查，不代表当前运行状态。")
                    .font(.callout).foregroundStyle(TZStyle.secondary)
                Text("\(report.applicationVersion) · \(report.timeZoneID) · \(report.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(TZStyle.secondary)
                ForEach(report.checks) { check in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: outcomeIcon(check.outcome)).foregroundStyle(outcomeColor(check.outcome))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(check.name).font(.subheadline.weight(.medium))
                            Text(check.detail).font(.caption).foregroundStyle(TZStyle.secondary).textSelection(.enabled)
                        }
                    }
                }
                if report.checks.isEmpty {
                    Text("这份记录没有检查项目。无法据此确认兼容性。")
                        .font(.caption).foregroundStyle(TZStyle.secondary)
                }
            } else {
                Label("尚无兼容性检查记录", systemImage: "questionmark.circle")
                    .font(.callout).foregroundStyle(TZStyle.secondary)
                Text("应用正常启动只说明目标时区已传入启动环境。请在应用内核对时间显示与相关功能。")
                    .font(.caption).foregroundStyle(TZStyle.secondary)
            }
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 18) {
            explanationRow("clock", title: "仅改变应用启动时区", text: "TZBox 在启动时将目标时区传给应用进程，系统时间与系统时区保持不变。这里的“已应用”表示启动环境已设置；应用是否采用它取决于自身实现。")
            explanationRow("arrow.clockwise", title: "正常重启，原有资料保留", text: "已运行的应用需要先保存内容，再正常退出并重新启动。TZBox 继续使用原应用的资料、账号和设置。更改上方目标时区不会自动重启任何应用。")
            explanationRow("checkmark.shield", title: "按实际功能确认兼容性", text: "页面、插件、远端服务或账号可能有独立的时区设置。应核对需要使用的功能；模型的自然语言回答不能代替实际请求与时间数据的检查。")
            explanationRow("menubar.rectangle", title: "从菜单栏继续管理", text: "关闭窗口后仍可通过菜单栏打开 TZBox。退出 TZBox 不会关闭已经启动的应用；已保存的运行记录可在下次打开时继续识别。")
        }
    }

    private func explanationRow(_ icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(TZStyle.secondary)
                .frame(width: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(TZStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func outcomeIcon(_ outcome: VerificationOutcome) -> String {
        switch outcome {
        case .passed: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .unverified: return "questionmark.circle"
        }
    }

    private func outcomeColor(_ outcome: VerificationOutcome) -> Color {
        switch outcome {
        case .passed: return .green
        case .failed: return .orange
        case .unverified: return .secondary
        }
    }
}
