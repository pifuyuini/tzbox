import Foundation
#if canImport(XCTest)
import XCTest
#else
import TZBoxTestSupport
#endif
@testable import TZBoxCore

final class ChromeProbeTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1704152700)

    private func tokyoSnapshot() -> [String: Any] {
        let local = [
            [2024, 1, 2, 8, 45, 0], [2024, 1, 15, 21, 0, 0], [2024, 7, 15, 21, 0, 0],
            [2024, 3, 10, 15, 59, 59], [2024, 3, 10, 16, 0, 0],
            [2024, 11, 3, 14, 59, 59], [2024, 11, 3, 15, 0, 0]
        ]
        return ["zone": "Asia/Tokyo", "canonicalTarget": "Asia/Tokyo", "now": 1704152700000.0,
                "offset": -540, "samples": zip(ChromeProbe.instants, local).map {
                    ["timestamp": $0.0, "offset": -540, "local": $0.1] as [String: Any]
                }]
    }

    private func assess(_ snapshot: [String: Any]) -> [VerificationCheck] {
        ChromeProbe.checks(snapshot: snapshot, context: "test", timeZoneID: "Asia/Tokyo",
                           before: instant.addingTimeInterval(-0.01), after: instant.addingTimeInterval(0.01))
    }

    func testTokyoCrossDateAndFixedInstantsPass() {
        XCTAssertTrue(assess(tokyoSnapshot()).allSatisfy { $0.outcome == .passed })
    }

    func testWrongClockFailsEvenWhenTimeZoneAndOffsetAreCorrect() {
        var snapshot = tokyoSnapshot()
        snapshot["now"] = 1704152700000.0 + 60_000
        let checks = assess(snapshot)
        XCTAssertEqual(checks[0].outcome, .passed)
        XCTAssertEqual(checks[1].outcome, .passed)
        XCTAssertEqual(checks[2].outcome, .failed)
    }

    func testHostTimezoneLeakFailsZoneAndOffset() {
        var snapshot = tokyoSnapshot()
        snapshot["zone"] = "UTC"
        snapshot["offset"] = 0
        let checks = assess(snapshot)
        XCTAssertEqual(checks[0].outcome, .failed)
        XCTAssertEqual(checks[1].outcome, .failed)
        XCTAssertEqual(checks[2].outcome, .passed)
    }

    func testMissingSamplesDoNotCountAsVerified() {
        var snapshot = tokyoSnapshot()
        snapshot["samples"] = [] as [[String: Any]]
        XCTAssertEqual(assess(snapshot)[3].outcome, .failed)
        XCTAssertTrue(assess([:]).allSatisfy { $0.outcome == .failed })
    }

    func testIncorrectHistoricalDateIsDetected() {
        var snapshot = tokyoSnapshot()
        var samples = snapshot["samples"] as! [[String: Any]]
        samples[0]["local"] = [2024, 1, 1, 8, 45, 0]
        snapshot["samples"] = samples
        XCTAssertEqual(assess(snapshot)[3].outcome, .failed)
    }

    func testHalfHourZoneAcceptsBrowserCanonicalAlias() {
        let local = [
            [2024, 1, 2, 5, 15, 0], [2024, 1, 15, 17, 30, 0], [2024, 7, 15, 17, 30, 0],
            [2024, 3, 10, 12, 29, 59], [2024, 3, 10, 12, 30, 0],
            [2024, 11, 3, 11, 29, 59], [2024, 11, 3, 11, 30, 0]
        ]
        let snapshot: [String: Any] = [
            "zone": "Asia/Calcutta", "canonicalTarget": "Asia/Calcutta",
            "now": 1704152700000.0, "offset": -330,
            "samples": zip(ChromeProbe.instants, local).map {
                ["timestamp": $0.0, "offset": -330, "local": $0.1] as [String: Any]
            }
        ]
        let checks = ChromeProbe.checks(snapshot: snapshot, context: "half-hour", timeZoneID: "Asia/Kolkata",
                                        before: instant, after: instant)
        XCTAssertTrue(checks.allSatisfy { $0.outcome == .passed })
    }

    func testNewYorkDSTTransitionsUseHistoricalOffsets() {
        let local = [
            [2024, 1, 1, 18, 45, 0], [2024, 1, 15, 7, 0, 0], [2024, 7, 15, 8, 0, 0],
            [2024, 3, 10, 1, 59, 59], [2024, 3, 10, 3, 0, 0],
            [2024, 11, 3, 1, 59, 59], [2024, 11, 3, 1, 0, 0]
        ]
        let offsets = [300, 300, 240, 300, 240, 240, 300]
        let snapshot: [String: Any] = [
            "zone": "America/New_York", "canonicalTarget": "America/New_York",
            "now": 1704152700000.0, "offset": 300,
            "samples": ChromeProbe.instants.enumerated().map { index, timestamp in
                ["timestamp": timestamp, "offset": offsets[index], "local": local[index]] as [String: Any]
            }
        ]
        let checks = ChromeProbe.checks(snapshot: snapshot, context: "DST", timeZoneID: "America/New_York",
                                        before: instant, after: instant)
        XCTAssertTrue(checks.allSatisfy { $0.outcome == .passed })
    }
}
