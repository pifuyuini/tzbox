import Foundation

public enum TimeZones {
    public static let identifiers: [String] = Array(
        Set(TimeZone.knownTimeZoneIdentifiers).union(["Etc/UTC", "UTC"])
    ).sorted()

    private static let identifierSet = Set(identifiers)

    public static var defaultIdentifier: String {
        let identifier = TimeZone.current.identifier
        return isValid(identifier) ? identifier : "Etc/UTC"
    }

    public static func isValid(_ id: String) -> Bool {
        (identifierSet.contains(id) || id.contains("/")) && TimeZone(identifier: id) != nil
    }

    public static func offsetLabel(for id: String, at date: Date = Date()) -> String {
        guard isValid(id), let zone = TimeZone(identifier: id) else { return "未知时区" }
        let seconds = zone.secondsFromGMT(for: date)
        let magnitude = abs(seconds)
        let sign = seconds < 0 ? "-" : "+"
        let base = String(format: "UTC%@%02d:%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
        return magnitude % 60 == 0 ? base : base + String(format: ":%02d", magnitude % 60)
    }

    public static func localTime(for id: String, at date: Date = Date()) -> String {
        guard isValid(id), let zone = TimeZone(identifier: id) else { return "未知时区" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
