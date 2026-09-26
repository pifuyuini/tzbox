import Foundation
#if canImport(XCTest)
import XCTest
#else
import TZBoxTestSupport
#endif
@testable import TZBoxCore

@MainActor
private final class FakeCDPTransport: CDPTransport {
    var sent: [[String: Any]] = []
    private var incoming: [Result<String, Error>] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var cancelled = false

    func send(_ text: String) async throws {
        if cancelled { throw CancellationError() }
        sent.append(try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
    }

    func receive() async throws -> String {
        if !incoming.isEmpty { return try incoming.removeFirst().get() }
        if cancelled { throw CancellationError() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func push(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        deliver(.success(String(data: data, encoding: .utf8)!))
    }

    func fail() { deliver(.failure(CDPError(message: "fixture connection dropped"))) }

    func cancel() {
        cancelled = true
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }

    private func deliver(_ result: Result<String, Error>) {
        if let waiter {
            self.waiter = nil
            waiter.resume(with: result)
        } else { incoming.append(result) }
    }

    func waitForMessages(_ count: Int) async throws {
        for _ in 0..<100 {
            if sent.count >= count { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw CDPError(message: "fixture did not receive expected messages")
    }
}

@MainActor
final class ChromeProtocolTests: XCTestCase {
    func testOutOfOrderRepliesKeepRequestAndSessionIdentity() async throws {
        let transport = FakeCDPTransport()
        let client = CDPClient(transport: transport)
        client.start()
        defer { client.close() }
        let first = Task { try await client.request("Runtime.evaluate", params: ["expression": "1"], sessionID: "page-A") }
        let second = Task { try await client.request("Runtime.evaluate", params: ["expression": "2"], sessionID: "page-B") }
        try await transport.waitForMessages(2)
        let firstWire = transport.sent.first { $0["sessionId"] as? String == "page-A" }!
        let secondWire = transport.sent.first { $0["sessionId"] as? String == "page-B" }!
        try transport.push(["id": secondWire["id"]!, "result": ["answer": 2]])
        try transport.push(["id": firstWire["id"]!, "result": ["answer": 1]])
        let secondResult = try await second.value
        let firstResult = try await first.value
        XCTAssertEqual(secondResult["answer"] as? Int, 2)
        XCTAssertEqual(firstResult["answer"] as? Int, 1)
    }

    func testEventIsDeliveredBeforePendingRequestReply() async throws {
        let transport = FakeCDPTransport()
        let client = CDPClient(transport: transport)
        var eventMethod: String?
        var eventSession: String?
        var childSession: String?
        client.onEvent = { method, params, session in
            eventMethod = method
            eventSession = session
            childSession = params["sessionId"] as? String
        }
        client.start()
        defer { client.close() }
        let request = Task { try await client.request("Target.setAutoAttach") }
        try await transport.waitForMessages(1)
        try transport.push(["method": "Target.attachedToTarget", "sessionId": "parent", "params": ["sessionId": "child"]])
        try transport.push(["id": transport.sent[0]["id"]!, "result": [:]])
        _ = try await request.value
        XCTAssertEqual(eventMethod, "Target.attachedToTarget")
        XCTAssertEqual(eventSession, "parent")
        XCTAssertEqual(childSession, "child")
    }

    func testDisconnectReleasesAllPendingRequestsAndNotifiesOnce() async throws {
        let transport = FakeCDPTransport()
        let client = CDPClient(transport: transport)
        var disconnects = 0
        client.onDisconnect = { _ in disconnects += 1 }
        client.start()
        let first = Task { try await client.request("A", timeout: 2) }
        let second = Task { try await client.request("B", timeout: 2) }
        try await transport.waitForMessages(2)
        transport.fail()
        do { _ = try await first.value; XCTFail("disconnect must fail first request") } catch {}
        do { _ = try await second.value; XCTFail("disconnect must fail second request") } catch {}
        client.close()
        XCTAssertEqual(disconnects, 1)
        XCTAssertFalse(client.isConnected)
    }

    func testTimeoutDoesNotMisrouteLateReplyToNextRequest() async throws {
        let transport = FakeCDPTransport()
        let client = CDPClient(transport: transport)
        client.start()
        defer { client.close() }
        let expired = Task { try await client.request("slow", timeout: 0.02) }
        try await transport.waitForMessages(1)
        do { _ = try await expired.value; XCTFail("slow request must time out") } catch {
            XCTAssertTrue(error.localizedDescription.contains("slow"))
        }
        let next = Task { try await client.request("next") }
        try await transport.waitForMessages(2)
        try transport.push(["id": transport.sent[0]["id"]!, "result": ["answer": "late"]])
        try transport.push(["id": transport.sent[1]["id"]!, "result": ["answer": "current"]])
        let result = try await next.value
        XCTAssertEqual(result["answer"] as? String, "current")
        XCTAssertTrue(client.isConnected)
    }

    func testProtocolErrorIsNotReportedAsSuccessfulEmptyResult() async throws {
        let transport = FakeCDPTransport()
        let client = CDPClient(transport: transport)
        client.start()
        defer { client.close() }
        let request = Task { try await client.request("Emulation.setTimezoneOverride", sessionID: "worker") }
        try await transport.waitForMessages(1)
        try transport.push(["id": transport.sent[0]["id"]!, "error": ["code": -32601, "message": "method unavailable"]])
        do { _ = try await request.value; XCTFail("unsupported command must fail") } catch {
            XCTAssertEqual(error.localizedDescription, "method unavailable")
        }
    }

    func testCancellingRequestReleasesContinuationWithoutClosingConnection() async throws {
        let transport = FakeCDPTransport()
        let client = CDPClient(transport: transport)
        client.start()
        defer { client.close() }
        let request = Task { try await client.request("long request", timeout: 5) }
        try await transport.waitForMessages(1)
        request.cancel()
        do { _ = try await request.value; XCTFail("cancelled request must fail") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(client.isConnected)
    }
}
