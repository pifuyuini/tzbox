import SwiftUI
import TZBoxCore

struct TimeZoneChooser: View {
    let selected: String
    let choose: (String) -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var common: [String] {
        var identifiers = [selected, "Asia/Shanghai", "Asia/Tokyo", "Europe/London", "America/New_York", "America/Los_Angeles", "Etc/UTC"]
        var seen: Set<String> = []
        identifiers = identifiers.filter { seen.insert($0).inserted && TimeZones.isValid($0) }
        return identifiers
    }
    private var matches: [String] {
        let value = searchText
        var identifiers = TimeZones.identifiers.filter {
            $0.localizedCaseInsensitiveContains(value) || $0.replacingOccurrences(of: "_", with: " ").localizedCaseInsensitiveContains(value)
        }
        // Foundation accepts valid IANA aliases that are absent from the canonical list.
        if TimeZones.isValid(value), !identifiers.contains(value) { identifiers.insert(value, at: 0) }
        return identifiers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("选择目标时区").font(.headline)
                Spacer()
                Image(systemName: "globe").foregroundStyle(TZStyle.secondary)
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(TZStyle.secondary)
                TextField("搜索城市或输入完整 IANA 标识", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        if TimeZones.isValid(searchText) { choose(searchText) }
                        else if matches.count == 1, let identifier = matches.first { choose(identifier) }
                    }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(TZStyle.secondary)
                    }
                    .buttonStyle(.plain).accessibilityLabel("清空搜索")
                }
            }
            .padding(9)
            .softSurface(radius: 10, recessed: true)

            if !searchText.isEmpty && matches.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(TZStyle.secondary)
                    Text("未找到匹配时区").font(.subheadline)
                    Text("试试 Tokyo、New York 或 US/Pacific。")
                        .font(.caption).foregroundStyle(TZStyle.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        if searchText.isEmpty {
                            sectionTitle("常用时区")
                            ForEach(common, id: \.self) { option($0) }
                            sectionTitle("全部时区").padding(.top, 10)
                            ForEach(TimeZones.identifiers.filter { !common.contains($0) }, id: \.self) { option($0) }
                        } else {
                            ForEach(matches, id: \.self) { option($0) }
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
            Divider()
            Text("选定后，运行中的应用需分别重新应用。")
                .font(.caption).foregroundStyle(TZStyle.secondary)
        }
        .padding(22)
        .frame(width: 440, height: 500)
        .background(TZStyle.canvas)
        .foregroundStyle(TZStyle.text)
        .tint(TZStyle.accent)
        .background(SmokeWindowMarker(identifier: "TZBoxTimeZoneChooser"))
        .onAppear { searchFocused = true }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(TZStyle.secondary).padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func option(_ identifier: String) -> some View {
        Button { choose(identifier) } label: {
            HStack(spacing: 9) {
                Image(systemName: identifier == selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(identifier == selected ? TZStyle.accent : TZStyle.secondary.opacity(0.65))
                    .font(.system(size: 13))
                Text(identifier).font(.system(size: 12, weight: identifier == selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(TimeZones.offsetLabel(for: identifier))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(TZStyle.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background {
                if identifier == selected { Color.clear.softSurface(radius: 9, recessed: true) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(identifier)，\(TimeZones.offsetLabel(for: identifier))\(identifier == selected ? "，当前目标" : "")")
    }
}
