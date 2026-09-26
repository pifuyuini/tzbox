import Foundation

/// The transport seam keeps protocol tests independent of an installed browser.
@MainActor
protocol CDPTransport: AnyObject {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func cancel()
}

@MainActor
final class WebSocketCDPTransport: CDPTransport {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask

    init(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
        socket = session.webSocketTask(with: url)
        socket.resume()
    }

    func send(_ text: String) async throws { try await socket.send(.string(text)) }

    func receive() async throws -> String {
        switch try await socket.receive() {
        case .string(let text): return text
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw CDPError(message: "Chrome 返回了无法读取的消息。")
            }
            return text
        @unknown default: throw CDPError(message: "Chrome 返回了未知消息格式。")
        }
    }

    func cancel() {
        socket.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}

struct CDPError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class CDPClient {
    typealias Object = [String: Any]
    var onEvent: ((String, Object, String?) -> Void)?
    var onDisconnect: ((Error) -> Void)?

    private struct Pending {
        let continuation: CheckedContinuation<Object, Error>
        let timeout: Task<Void, Never>
    }
    private let transport: CDPTransport
    private var pending: [Int: Pending] = [:]
    private var nextID = 0
    private var receiveTask: Task<Void, Never>?
    private(set) var isConnected = false

    init(transport: CDPTransport) { self.transport = transport }
    convenience init(url: URL) { self.init(transport: WebSocketCDPTransport(url: url)) }

    func start() {
        guard receiveTask == nil else { return }
        isConnected = true
        receiveTask = Task { [weak self, transport] in
            do {
                while !Task.isCancelled {
                    let text = try await transport.receive()
                    guard let self, self.isConnected else { return }
                    try self.consume(text)
                }
            } catch {
                self?.finishConnection(error: error, notify: true)
            }
        }
    }

    func request(_ method: String, params: Object = [:], sessionID: String? = nil,
                 timeout: TimeInterval = 8) async throws -> Object {
        guard isConnected else { throw CDPError(message: "Chrome 控制连接尚未建立。") }
        nextID += 1
        let id = nextID
        var envelope: Object = ["id": id, "method": method, "params": params]
        if let sessionID { envelope["sessionId"] = sessionID }
        let data = try JSONSerialization.data(withJSONObject: envelope)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CDPError(message: "无法编码 Chrome 控制消息。")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(max(0.001, timeout) * 1_000_000_000)) }
                    catch { return }
                    self?.finish(id: id, result: .failure(CDPError(message: "Chrome 命令超时：\(method)")))
                }
                let entry = Pending(continuation: continuation, timeout: timeoutTask)
                storePending(entry, id: id)
                Task { [weak self, transport] in
                    do { try await transport.send(text) }
                    catch { self?.finishConnection(error: error, notify: true) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id: id, result: .failure(CancellationError()))
            }
        }
    }

    func close() {
        finishConnection(error: CDPError(message: "Chrome 控制连接已关闭。"), notify: false)
    }

    private func storePending(_ request: Pending, id: Int) {
        pending[id] = request
    }

    private func consume(_ text: String) throws {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? Object else {
            throw CDPError(message: "Chrome 消息不是 JSON 对象。")
        }
        if let id = object["id"] as? Int {
            if let error = object["error"] as? Object {
                let detail = error["message"] as? String ?? "未知协议错误"
                finish(id: id, result: .failure(CDPError(message: detail)))
            } else {
                finish(id: id, result: .success(object["result"] as? Object ?? [:]))
            }
        } else if let method = object["method"] as? String {
            onEvent?(method, object["params"] as? Object ?? [:], object["sessionId"] as? String)
        }
    }

    private func finish(id: Int, result: Result<Object, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }

    private func finishConnection(error: Error, notify: Bool) {
        guard isConnected else { return }
        isConnected = false
        receiveTask?.cancel()
        receiveTask = nil
        transport.cancel()
        let requests = pending
        pending.removeAll()
        for request in requests.values {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
        if notify { onDisconnect?(error) }
    }
}
