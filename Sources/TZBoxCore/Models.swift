import Foundation

public enum AppBackend: String, Codable {
    case chrome
    case native
}

public struct AppEntry: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var applicationURL: URL
    public var backend: AppBackend

    public init(id: UUID = UUID(), name: String, applicationURL: URL, backend: AppBackend) {
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
