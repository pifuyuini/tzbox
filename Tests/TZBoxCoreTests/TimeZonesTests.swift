import Foundation
#if canImport(XCTest)
import XCTest
#else
import TZBoxTestSupport
#endif
@testable import TZBoxCore

final class TimeZonesTests: XCTestCase {
    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    func testIdentifiersRejectFixedOffsetStringsAndInvalidIdentifiers() {
        XCTAssertTrue(TimeZones.isValid("Etc/UTC"))
        XCTAssertTrue(TimeZones.isValid("Asia/Tokyo"))
        XCTAssertTrue(TimeZones.isValid("Asia/Kolkata"))
        XCTAssertTrue(TimeZones.isValid("Asia/Calcutta"))
        XCTAssertFalse(TimeZones.isValid("GMT+0900"))
        XCTAssertFalse(TimeZones.isValid("UTC+9"))
        XCTAssertFalse(TimeZones.isValid("Invalid/Timezone"))
        XCTAssertFalse(TimeZones.isValid(""))
        XCTAssertEqual(TimeZones.identifiers, TimeZones.identifiers.sorted())
        XCTAssertEqual(TimeZones.identifiers.count, Set(TimeZones.identifiers).count)
    }

    func testDaylightSavingUsesRulesForTheRequestedInstant() {
        let winter = date("2024-01-15T12:00:00Z")
        let summer = date("2024-07-15T12:00:00Z")
        XCTAssertEqual(TimeZones.offsetLabel(for: "America/New_York", at: winter), "UTC-05:00")
        XCTAssertEqual(TimeZones.offsetLabel(for: "America/New_York", at: summer), "UTC-04:00")
        XCTAssertEqual(TimeZones.localTime(for: "America/New_York", at: winter), "2024-01-15 07:00:00")
        XCTAssertEqual(TimeZones.localTime(for: "America/New_York", at: summer), "2024-07-15 08:00:00")
    }

    func testDaylightSavingBoundarySkipsTheMissingHour() {
        let before = date("2024-03-10T06:59:59Z")
        let after = date("2024-03-10T07:00:00Z")
        XCTAssertEqual(TimeZones.localTime(for: "America/New_York", at: before), "2024-03-10 01:59:59")
        XCTAssertEqual(TimeZones.localTime(for: "America/New_York", at: after), "2024-03-10 03:00:00")
    }

    func testHalfAndQuarterHourOffsets() {
        let instant = date("2024-01-15T12:00:00Z")
        XCTAssertEqual(TimeZones.offsetLabel(for: "Asia/Kolkata", at: instant), "UTC+05:30")
        XCTAssertEqual(TimeZones.offsetLabel(for: "Asia/Kathmandu", at: instant), "UTC+05:45")
        XCTAssertEqual(TimeZones.offsetLabel(for: "America/St_Johns", at: instant), "UTC-03:30")
        XCTAssertEqual(TimeZones.localTime(for: "Asia/Kolkata", at: instant), "2024-01-15 17:30:00")
    }

    func testDateCrossingAndUTCInstantAreIndependent() {
        let instant = date("2024-01-01T00:30:00Z")
        let timestamp = instant.timeIntervalSince1970
        XCTAssertEqual(TimeZones.localTime(for: "America/Los_Angeles", at: instant), "2023-12-31 16:30:00")
        XCTAssertEqual(TimeZones.localTime(for: "Asia/Tokyo", at: instant), "2024-01-01 09:30:00")
        XCTAssertEqual(TimeZones.localTime(for: "Etc/UTC", at: instant), "2024-01-01 00:30:00")
        XCTAssertEqual(instant.timeIntervalSince1970, timestamp)
    }
}
