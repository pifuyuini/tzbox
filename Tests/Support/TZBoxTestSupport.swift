import Foundation

/// Assertions for the Command Line Tools self-test runner, not Apple XCTest.
open class XCTestCase {
    public init() {}
    open func setUpWithError() throws {}
    open func tearDownWithError() throws {}
}

public enum TestRecorder {
    public private(set) static var failureCount = 0

    public static func recordFailure(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        failureCount += 1
        print("  FAIL \(file):\(line): \(message)")
    }
}

private func failureMessage(_ description: String, _ message: String) -> String {
    message.isEmpty ? description : "\(description) — \(message)"
}

public func XCTFail(_ message: String = "Explicit test failure", file: StaticString = #filePath, line: UInt = #line) {
    TestRecorder.recordFailure(message, file: file, line: line)
}

public func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try !expression() {
            TestRecorder.recordFailure(failureMessage("Expected true", message()), file: file, line: line)
        }
    } catch {
        TestRecorder.recordFailure(failureMessage("Expression threw: \(error)", message()), file: file, line: line)
    }
}

public func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try expression() {
            TestRecorder.recordFailure(failureMessage("Expected false", message()), file: file, line: line)
        }
    } catch {
        TestRecorder.recordFailure(failureMessage("Expression threw: \(error)", message()), file: file, line: line)
    }
}

public func XCTAssertEqual<T: Equatable>(_ expression1: @autoclosure () throws -> T, _ expression2: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let lhs = try expression1()
        let rhs = try expression2()
        if lhs != rhs {
            TestRecorder.recordFailure(failureMessage("Values differ: \(String(describing: lhs)) != \(String(describing: rhs))", message()), file: file, line: line)
        }
    } catch {
        TestRecorder.recordFailure(failureMessage("Expression threw: \(error)", message()), file: file, line: line)
    }
}

public func XCTAssertNil<T>(_ expression: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        if let value = try expression() {
            TestRecorder.recordFailure(failureMessage("Expected nil, received \(String(describing: value))", message()), file: file, line: line)
        }
    } catch {
        TestRecorder.recordFailure(failureMessage("Expression threw: \(error)", message()), file: file, line: line)
    }
}

public func XCTAssertNotNil<T>(_ expression: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try expression() == nil {
            TestRecorder.recordFailure(failureMessage("Expected a non-nil value", message()), file: file, line: line)
        }
    } catch {
        TestRecorder.recordFailure(failureMessage("Expression threw: \(error)", message()), file: file, line: line)
    }
}

public func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line, _ errorHandler: (Error) -> Void = { _ in }) {
    do {
        _ = try expression()
        TestRecorder.recordFailure(failureMessage("Expected an error, but expression succeeded", message()), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

private struct UnwrapFailure: Error {}

public func XCTUnwrap<T>(_ expression: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    let value: T?
    do {
        value = try expression()
    } catch {
        TestRecorder.recordFailure(failureMessage("Expression threw: \(error)", message()), file: file, line: line)
        throw error
    }
    guard let value else {
        TestRecorder.recordFailure(failureMessage("Unable to unwrap nil", message()), file: file, line: line)
        throw UnwrapFailure()
    }
    return value
}
