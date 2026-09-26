import Foundation

/// Pure probe generation and result assessment; it never changes a clock or page API.
enum ChromeProbe {
    static let instants: [Double] = [
        1704152700000, // 2024-01-01 23:45 UTC: crosses the date in eastern zones.
        1705320000000, 1721044800000, // Northern winter and summer.
        1710053999000, 1710054000000, // US spring DST transition.
        1730613599000, 1730613600000  // US autumn DST transition.
    ]

    static func quoted(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
    }

    static func expression(timeZoneID: String) -> String {
        let timestamps = instants.map { String(format: "%.0f", $0) }.joined(separator: ",")
        return """
        (() => {
          const now = Date.now();
          const sample = timestamp => {
            const d = new Date(timestamp);
            return {timestamp, offset:d.getTimezoneOffset(),
              local:[d.getFullYear(),d.getMonth()+1,d.getDate(),d.getHours(),d.getMinutes(),d.getSeconds()]};
          };
          return {zone:Intl.DateTimeFormat().resolvedOptions().timeZone,
            canonicalTarget:new Intl.DateTimeFormat('en',{timeZone:\(quoted(timeZoneID))}).resolvedOptions().timeZone,
            now,offset:new Date(now).getTimezoneOffset(),samples:[\(timestamps)].map(sample)};
        })()
        """
    }

    static func checks(snapshot: [String: Any], context: String, timeZoneID: String,
                       before: Date, after: Date) -> [VerificationCheck] {
        guard let zone = TimeZone(identifier: timeZoneID) else {
            return [VerificationCheck(name: "\(context) / 时区", outcome: .failed, detail: "无效的目标时区。")]
        }
        let observed = snapshot["zone"] as? String
        let canonical = snapshot["canonicalTarget"] as? String
        let zoneMatches = observed != nil && canonical != nil && observed == canonical
        let now = (snapshot["now"] as? NSNumber)?.doubleValue
        let offset = (snapshot["offset"] as? NSNumber)?.intValue
        let observedDate = now.map { Date(timeIntervalSince1970: $0 / 1000) }
        let expectedOffset = observedDate.map { -zone.secondsFromGMT(for: $0) / 60 }
        let offsetMatches = offset != nil && expectedOffset != nil && offset == expectedOffset
        let clockMatches = now.map {
            $0 >= before.timeIntervalSince1970 * 1000 - 250 && $0 <= after.timeIntervalSince1970 * 1000 + 250
        } ?? false
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let samples = snapshot["samples"] as? [[String: Any]] ?? []
        var sampleMatches = samples.count == instants.count
        for (index, sample) in samples.enumerated() {
            guard index < instants.count,
                  let timestamp = (sample["timestamp"] as? NSNumber)?.doubleValue,
                  timestamp == instants[index],
                  let sampleOffset = (sample["offset"] as? NSNumber)?.intValue,
                  let local = sample["local"] as? [Int] else { sampleMatches = false; continue }
            let date = Date(timeIntervalSince1970: timestamp / 1000)
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let expected = [components.year!, components.month!, components.day!, components.hour!, components.minute!, components.second!]
            if sampleOffset != -zone.secondsFromGMT(for: date) / 60 || local != expected { sampleMatches = false }
        }
        return [
            VerificationCheck(name: "\(context) / Intl 时区", outcome: zoneMatches ? .passed : .failed,
                              detail: "目标 \(timeZoneID)，浏览器规范名 \(canonical ?? "缺失")，实际 \(observed ?? "缺失")。"),
            VerificationCheck(name: "\(context) / UTC 偏移", outcome: offsetMatches ? .passed : .failed,
                              detail: "getTimezoneOffset 为 \(offset.map(String.init) ?? "缺失") 分钟；期望 \(expectedOffset.map(String.init) ?? "未知")。"),
            VerificationCheck(name: "\(context) / 真实时刻", outcome: clockMatches ? .passed : .failed,
                              detail: "Date.now() 应落在宿主请求前后采样区间内（允许 250 ms 通信边界误差）。"),
            VerificationCheck(name: "\(context) / 固定时刻转换", outcome: sampleMatches ? .passed : .failed,
                              detail: "核对跨日期、冬夏季及美国夏令时切换瞬间的偏移和年月日时分秒；覆盖 7 个真实 UTC 时间戳。")
        ]
    }
}

@MainActor
extension ChromeController {
    func performBasicCheck() async throws -> VerificationReport {
        let target = try await createPage(url: "about:blank")
        do {
            var checks = try await probe(target: target, context: "当前检查页")
            checks += [
                VerificationCheck(name: "新标签和弹窗", outcome: .unverified, detail: "本次仅检查当前诊断页；使用开发诊断逐项验证。"),
                VerificationCheck(name: "跨域 iframe", outcome: .unverified, detail: "本次未创建跨域 iframe。"),
                VerificationCheck(name: "Worker", outcome: .unverified, detail: "本次未检查 Dedicated、Shared 或 Service Worker。")
            ]
            await closeTarget(target.id)
            return VerificationReport(applicationVersion: applicationVersion, timeZoneID: timeZoneID, checks: checks)
        } catch {
            await closeTarget(target.id)
            throw error
        }
    }

    /// Developer-only integration diagnostics against the repository's loopback fixtures.
    /// This is opt-in; ordinary GUI checks do not start a fixture server or contact sites.
    public func runDiagnostics(fixtureBaseURL: URL) async throws -> VerificationReport {
        guard ["127.0.0.1", "localhost"].contains(fixtureBaseURL.host ?? ""),
              fixtureBaseURL.scheme == "http", isActive, client?.isConnected == true else {
            throw TZBoxError("开发诊断需要运行中的受控 Chrome 和本机 HTTP fixture 地址。")
        }
        let token = UUID().uuidString
        func fixture(_ path: String) -> String {
            var url = URLComponents(url: fixtureBaseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "tzbox", value: token)]
            return url.url!.absoluteString
        }
        let pageURL = fixture("page")
        var ownTargets: [String] = []
        var checks: [VerificationCheck] = []
        do {
            let page = try await createPage(url: pageURL)
            ownTargets.append(page.id)
            try await waitForPage(page, url: pageURL)
            checks += try await probe(target: page, context: "基础页面")

            let second = try await createPage(url: pageURL + "-tab")
            ownTargets.append(second.id)
            try await waitForPage(second, url: pageURL + "-tab")
            checks += try await probe(target: second, context: "新标签页")

            do {
                let popupURL = pageURL + "-popup"
                _ = try await evaluate(sessionID: page.sessionID,
                                       expression: "window.open(\(ChromeProbe.quoted(popupURL)), '_blank') !== null")
                let popup = try await findTarget(url: popupURL, kind: "page")
                ownTargets.append(popup.id)
                try await waitForPage(popup, url: popupURL)
                checks += try await probe(target: popup, context: "弹窗")
            } catch { checks.append(failed("弹窗", error)) }

            do {
                var frameURL = URLComponents(string: fixture("frame"))!
                frameURL.host = fixtureBaseURL.host == "127.0.0.1" ? "localhost" : "127.0.0.1"
                let url = frameURL.url!.absoluteString
                _ = try await evaluate(sessionID: page.sessionID, expression: """
                new Promise((resolve,reject) => {
                  const frame = document.createElement('iframe');
                  const timer = setTimeout(() => reject(new Error('iframe load timeout')), 8000);
                  frame.onload = () => { clearTimeout(timer); resolve(true); };
                  frame.onerror = () => { clearTimeout(timer); reject(new Error('iframe load failed')); };
                  frame.src = \(ChromeProbe.quoted(url)); document.body.appendChild(frame);
                })
                """)
                checks += try await probeFrame(parent: page, url: url)
            } catch { checks.append(failed("跨域 iframe", error)) }

            let expression = ChromeProbe.expression(timeZoneID: timeZoneID)
            let workerURL = fixture("worker.js")
            let workerExpression = """
            new Promise((resolve,reject) => {
              const worker = new Worker(\(ChromeProbe.quoted(workerURL)));
              const timer = setTimeout(() => { worker.terminate(); reject(new Error('Worker timeout')); }, 8000);
              worker.onmessage = e => { clearTimeout(timer); worker.terminate(); resolve(e.data); };
              worker.onerror = e => { clearTimeout(timer); worker.terminate(); reject(new Error(e.message)); };
              worker.postMessage({expression:\(ChromeProbe.quoted(expression))});
            })
            """
            checks += await probeExpression(target: page, expression: workerExpression, context: "Dedicated Worker")

            let serviceURL = fixture("service-worker.js")
            let serviceExpression = """
            (async () => {
              const registration = await navigator.serviceWorker.register(\(ChromeProbe.quoted(serviceURL)));
              try {
                const worker = registration.active || registration.waiting || registration.installing;
                if (!worker) throw new Error('No service worker');
                if (worker.state !== 'activated') await new Promise((resolve,reject) => {
                  const timer = setTimeout(() => reject(new Error('Service Worker activation timeout')), 6000);
                  worker.addEventListener('statechange', () => {
                    if (worker.state === 'activated') { clearTimeout(timer); resolve(); }
                    if (worker.state === 'redundant') { clearTimeout(timer); reject(new Error('Service Worker redundant')); }
                  });
                });
                return await new Promise((resolve,reject) => {
                  const channel = new MessageChannel();
                  const timer = setTimeout(() => { channel.port1.close(); reject(new Error('Service Worker reply timeout')); }, 4000);
                  channel.port1.onmessage = e => { clearTimeout(timer); channel.port1.close(); resolve(e.data); };
                  worker.postMessage({expression:\(ChromeProbe.quoted(expression))}, [channel.port2]);
                });
              } finally { await registration.unregister(); }
            })()
            """
            checks += await probeExpression(target: page, expression: serviceExpression, context: "Service Worker")
            checks.append(VerificationCheck(name: "Shared Worker", outcome: .unverified,
                                            detail: "首版开发诊断未覆盖 Shared Worker，不能据其他 Worker 结果推断。"))
            checks.append(VerificationCheck(name: "登录资料跨浏览器重启", outcome: .unverified,
                                            detail: "需要在真实 Chrome 单独验证；本次运行不读取登录资料。"))
            for id in ownTargets.reversed() { await closeTarget(id) }
            let result = VerificationReport(applicationVersion: applicationVersion, timeZoneID: timeZoneID, checks: checks)
            publishReport(result, message: "开发诊断完成；各执行环境的结果分别列于报告。")
            return report ?? result
        } catch {
            for id in ownTargets.reversed() { await closeTarget(id) }
            throw error
        }
    }

    private func probe(target: Target, context: String) async throws -> [VerificationCheck] {
        let before = Date()
        let value = try await evaluate(sessionID: target.sessionID, expression: ChromeProbe.expression(timeZoneID: timeZoneID))
        let after = Date()
        guard let snapshot = value as? [String: Any] else { throw TZBoxError("时区探针未返回对象。") }
        return ChromeProbe.checks(snapshot: snapshot, context: context, timeZoneID: timeZoneID, before: before, after: after)
    }

    private func probeExpression(target: Target, expression: String, context: String) async -> [VerificationCheck] {
        do {
            let before = Date()
            let result = try await evaluate(sessionID: target.sessionID, expression: expression)
            let after = Date()
            guard let snapshot = result as? [String: Any] else { throw TZBoxError("Worker 探针未返回对象。") }
            return ChromeProbe.checks(snapshot: snapshot, context: context, timeZoneID: timeZoneID, before: before, after: after)
        } catch { return [failed(context, error)] }
    }

    private func waitForPage(_ target: Target, url: String) async throws {
        for _ in 0..<100 {
            if let value = try? await evaluate(sessionID: target.sessionID,
                    expression: "({url:location.href,ready:document.readyState})"),
               let status = value as? [String: Any], status["url"] as? String == url,
               status["ready"] as? String == "complete" { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw TZBoxError("本机 fixture 页面未加载完成。")
    }

    private func findTarget(url: String, kind: String) async throws -> Target {
        for _ in 0..<80 {
            guard let client else { throw TZBoxError("Chrome 控制连接不存在。") }
            let result = try await client.request("Target.getTargets")
            if let info = (result["targetInfos"] as? [[String: Any]])?.first(where: {
                $0["url"] as? String == url && $0["type"] as? String == kind
            }), let id = info["targetId"] as? String { return try await waitForTarget(id) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw TZBoxError("未发现已附加的 \(kind) 诊断目标。")
    }

    private func probeFrame(parent: Target, url: String) async throws -> [VerificationCheck] {
        guard let client else { throw TZBoxError("Chrome 控制连接不存在。") }
        let snapshot = try await client.request("Target.getTargets")
        if let info = (snapshot["targetInfos"] as? [[String: Any]])?.first(where: {
            $0["url"] as? String == url && $0["type"] as? String == "iframe"
        }), let id = info["targetId"] as? String {
            return try await probe(target: waitForTarget(id), context: "跨域 iframe")
        }
        // Some Chrome configurations keep cross-origin frames in the parent's process.
        let frameTree = try await client.request("Page.getFrameTree", sessionID: parent.sessionID)
        func findFrame(_ tree: [String: Any]) -> String? {
            if let frame = tree["frame"] as? [String: Any], frame["url"] as? String == url { return frame["id"] as? String }
            for child in tree["childFrames"] as? [[String: Any]] ?? [] {
                if let found = findFrame(child) { return found }
            }
            return nil
        }
        guard let tree = frameTree["frameTree"] as? [String: Any], let frameID = findFrame(tree) else {
            throw TZBoxError("未发现跨域 iframe 的执行环境。")
        }
        let world = try await client.request("Page.createIsolatedWorld", params: [
            "frameId": frameID, "worldName": "TZBox diagnostics"
        ], sessionID: parent.sessionID)
        guard let contextID = world["executionContextId"] as? Int else { throw TZBoxError("无法访问 iframe 诊断上下文。") }
        let before = Date()
        let response = try await client.request("Runtime.evaluate", params: [
            "expression": ChromeProbe.expression(timeZoneID: timeZoneID), "contextId": contextID, "returnByValue": true
        ], sessionID: parent.sessionID)
        let after = Date()
        guard let result = response["result"] as? [String: Any], let value = result["value"] as? [String: Any] else {
            throw TZBoxError("iframe 探针未返回对象。")
        }
        return ChromeProbe.checks(snapshot: value, context: "跨域 iframe", timeZoneID: timeZoneID, before: before, after: after)
    }

    private func failed(_ context: String, _ error: Error) -> VerificationCheck {
        VerificationCheck(name: "\(context) / 执行", outcome: .failed, detail: error.localizedDescription)
    }
}
