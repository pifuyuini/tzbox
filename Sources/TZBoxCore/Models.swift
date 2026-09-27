import Foundation

/// Kept for decoding settings written by TZBox 0.1. All applications now use the
/// same native launch path; .chrome no longer selects a separate browser profile.
public enum AppBackend: String, Codable {
    case chrome
    case native
}

public struct AppEntry: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var applicationURL: URL
    public var backend: AppBackend

    public init(id: UUID = UUID(), name: String, applicationURL: URL, backend: AppBackend = .native) {
        self.id = id
        self.name = name
        self.applicationURL = applicationURL
        self.backend = backend
    }
}

public struct Settings: Codable, Equatable {
    public var timeZoneID: String
    public var applications: [AppEntry]

    public init(timeZoneID: String = TimeZones.defaultIdentifier, applications: [AppEntry] = []) {
        self.timeZoneID = timeZoneID
        self.applications = applications
    }

    /// Migration changes only the launcher selection, never application data.
    var usingUnifiedLauncher: Settings {
        var updated = self
        updated.applications = applications.map { entry in
            var migrated = entry
            migrated.backend = .native
            return migrated
        }
        return updated
    }
}

public enum ProxyStatus: String {
    case stopped, runningUnmanaged, runningManaged, starting, stopping, failed
}

/// A process observation, not a claim that every time API respects its environment.
public struct ApplicationRuntime: Identifiable {
    public var id: UUID { entryID }
    public let entryID: UUID
    public let processID: Int32?
    public let timeZoneID: String?
    public let isManaged: Bool
    public let isBusy: Bool
    public let status: ProxyStatus
    public let applicationURL: URL?
    public let applicationVersion: String?
    public let instanceCount: Int

    public var isRunning: Bool { processID != nil }

    public init(entryID: UUID, processID: Int32? = nil, timeZoneID: String? = nil,
                isManaged: Bool = false, isBusy: Bool = false, status: ProxyStatus = .stopped,
                applicationURL: URL? = nil, applicationVersion: String? = nil, instanceCount: Int = 0) {
        self.entryID = entryID
        self.processID = processID
        self.timeZoneID = timeZoneID
        self.isManaged = isManaged
        self.isBusy = isBusy
        self.status = status
        self.applicationURL = applicationURL
        self.applicationVersion = applicationVersion
        self.instanceCount = instanceCount
    }

    public func needsReapplication(to targetTimeZoneID: String) -> Bool {
        isRunning && (!isManaged || timeZoneID != targetTimeZoneID)
    }
}

public enum VerificationOutcome: String, Codable {
    case passed
    case failed
    case unverified
}

public struct VerificationCheck: Codable, Identifiable {
    public var id: String { name }
    public var name: String
    public var outcome: VerificationOutcome
    public var detail: String

    public init(name: String, outcome: VerificationOutcome, detail: String) {
        self.name = name
        self.outcome = outcome
        self.detail = detail
    }
}

public struct VerificationReport: Codable {
    public var applicationVersion: String
    public var timeZoneID: String
    public var checkedAt: Date
    public var checks: [VerificationCheck]

    public init(applicationVersion: String, timeZoneID: String, checkedAt: Date = Date(), checks: [VerificationCheck]) {
        self.applicationVersion = applicationVersion
        self.timeZoneID = timeZoneID
        self.checkedAt = checkedAt
        self.checks = checks
    }

    /// Only a nonempty report with every check passing represents verified coverage.
    public var passed: Bool {
        !checks.isEmpty && checks.allSatisfy { $0.outcome == .passed }
    }
}

public struct TZBoxError: LocalizedError {
    private let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
