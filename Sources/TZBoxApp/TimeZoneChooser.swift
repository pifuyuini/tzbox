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
                Image(systemName: "globe").foregroundStyle(.secondary)
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索城市或输入完整 IANA 标识", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        if TimeZones.isValid(searchText) { choose(searchText) }
                        else if matches.count == 1, let identifier = matches.first { choose(identifier) }
                    }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).accessibilityLabel("清空搜索")
                }
            }
            .padding(9)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))

            if !searchText.isEmpty && matches.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.tertiary)
                    Text("未找到匹配时区").font(.subheadline)
                    Text("试试 Tokyo、New York 或 US/Pacific。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if searchText.isEmpty {
                        Section("常用时区") {
                            ForEach(common, id: \.self) { option($0) }
                        }
                        Section("全部时区") {
                            ForEach(TimeZones.identifiers.filter { !common.contains($0) }, id: \.self) { option($0) }
                        }
                    } else {
                        ForEach(matches, id: \.self) { option($0) }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            Divider()
            Text("选定后，运行中的应用需分别重新应用。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 440, height: 470)
        .background(SmokeWindowMarker(identifier: "TZBoxTimeZoneChooser"))
        .onAppear { searchFocused = true }
    }

    private func option(_ identifier: String) -> some View {
        Button { choose(identifier) } label: {
            HStack(spacing: 9) {
                Image(systemName: identifier == selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(identifier == selected ? Color.accentColor : Color.secondary.opacity(0.3))
                    .font(.system(size: 13))
                Text(identifier).font(.system(size: 12, weight: identifier == selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(TimeZones.offsetLabel(for: identifier))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(identifier)，\(TimeZones.offsetLabel(for: identifier))\(identifier == selected ? "，当前目标" : "")")
    }
}
