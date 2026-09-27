import Foundation

public struct SettingsStore {
    public let directory: URL

    public init(directory: URL = SettingsStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        if let isolatedDirectory = ProcessInfo.processInfo.environment["TZBOX_DATA_DIR"], !isolatedDirectory.isEmpty {
            return URL(fileURLWithPath: isolatedDirectory, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TZBox", isDirectory: true)
    }

    private var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    public func load() throws -> Settings {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return Settings() }
        let settings: Settings
        do {
            settings = try decoder().decode(Settings.self, from: Data(contentsOf: settingsURL))
        } catch {
            throw TZBoxError("无法读取设置，原文件已保留：\(error.localizedDescription)")
        }
        try validate(timeZoneID: settings.timeZoneID)
        return settings.usingUnifiedLauncher
    }

    public func save(_ settings: Settings) throws {
        try validate(timeZoneID: settings.timeZoneID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder().encode(settings.usingUnifiedLauncher).write(to: settingsURL, options: .atomic)
    }

    /// Called only by an explicit recovery action in the UI. Preserve the original
    /// file beside the replacement; no application profile or report is touched.
    public func backupAndReset() throws -> Settings {
        _ = try SettingsRecovery.backupExistingFile(at: settingsURL)
        let settings = Settings()
        try save(settings)
        return settings
    }

    public func saveReport(_ report: VerificationReport, for applicationID: UUID) throws {
        try validate(timeZoneID: report.timeZoneID)
        let url = reportURL(for: applicationID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder().encode(report).write(to: url, options: .atomic)
    }

    public func loadReport(for applicationID: UUID) -> VerificationReport? {
        let url = reportURL(for: applicationID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? decoder().decode(VerificationReport.self, from: Data(contentsOf: url))
    }

    private func reportURL(for applicationID: UUID) -> URL {
        directory.appendingPathComponent("Reports", isDirectory: true)
            .appendingPathComponent("\(applicationID.uuidString).json")
    }

    private func validate(timeZoneID: String) throws {
        guard TimeZones.isValid(timeZoneID) else {
            throw TZBoxError("无效的 IANA 时区：\(timeZoneID)")
        }
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum SettingsRecovery {
    /// A rename in the same directory preserves the exact original bytes.
    static func backupExistingFile(at url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        let name = "\(url.deletingPathExtension().lastPathComponent).backup-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).\(url.pathExtension)"
        let backup = url.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.moveItem(at: url, to: backup)
        return backup
    }
}
