#if canImport(XCTest)
import XCTest
#else
import TZBoxTestSupport
#endif
@testable import TZBoxCore

final class VerificationReportTests: XCTestCase {
    private func report(_ outcomes: [VerificationOutcome]) -> VerificationReport {
        VerificationReport(applicationVersion: "test", timeZoneID: "Asia/Tokyo", checks:
            outcomes.enumerated().map { index, outcome in
                VerificationCheck(name: "API \(index)", outcome: outcome, detail: "Recorded evidence")
            }
        )
    }

    func testEmptyReportDoesNotClaimCompatibility() {
        XCTAssertFalse(report([]).passed)
    }

    func testMixedCoverageDoesNotClaimFullSuccess() {
        XCTAssertFalse(report([.passed, .unverified]).passed)
        XCTAssertFalse(report([.passed, .failed]).passed)
        XCTAssertTrue(report([.passed, .passed]).passed)
    }
}
