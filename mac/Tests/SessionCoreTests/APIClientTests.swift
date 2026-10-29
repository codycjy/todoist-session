import XCTest
@testable import SessionCore

final class StubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> (Int, Data)

    private static let lock = NSLock()
    private static var _handler: Handler?
    static var handler: Handler? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); defer { lock.unlock() }; _handler = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// URLProtocol 收到的请求体通常是 httpBodyStream；读到 EOF（read 返回 0）或出错为止。
private func bodyData(of request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        data.append(buffer, count: n)
    }
    return data
}

final class APIClientTests: XCTestCase {
    override func setUp() { super.setUp(); StubURLProtocol.handler = nil }
    override func tearDown() { StubURLProtocol.handler = nil; super.tearDown() }

    func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return APIClient(baseURL: URL(string: "http://localhost:8787")!, token: "tok", session: URLSession(configuration: config))
    }

    func testCategoryWithoutArchivedFieldDecodesAsNotArchived() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"categories":[{"id":"c1","name":"Work","color":"blue","todoistProjectId":"p1"}]}"#.utf8))
        }
        let cats = try await makeClient().categories()
        XCTAssertEqual(cats.first?.archived, false)
    }

    func testAllCategoriesSendsAllQueryAndDecodesArchived() async throws {
        var captured: URLRequest?
        StubURLProtocol.handler = { req in
            captured = req
            return (200, Data(#"{"categories":[{"id":"c1","name":"Old","color":"red","todoistProjectId":null,"archived":true}]}"#.utf8))
        }
        let cats = try await makeClient().allCategories()
        XCTAssertEqual(captured?.url?.path, "/categories")
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "all", value: "1")])
        XCTAssertEqual(cats.first?.archived, true)
    }

    func testCategoryCrudRequests() async throws {
        var seen: [(String, String, [String: Any]?)] = []
        StubURLProtocol.handler = { req in
            let body = (try? JSONSerialization.jsonObject(with: bodyData(of: req))) as? [String: Any]
            seen.append((req.httpMethod ?? "", req.url?.path ?? "", body))
            if req.httpMethod == "DELETE" { return (200, Data(#"{"ok":true}"#.utf8)) }
            return (200, Data(#"{"category":{"id":"c1","name":"读书","color":"red","todoistProjectId":null}}"#.utf8))
        }
        let client = makeClient()
        let created = try await client.createCategory(name: "读书", color: "red")
        XCTAssertEqual(created.id, "c1")
        _ = try await client.updateCategory(id: "c1", name: "读书")
        try await client.deleteCategory(id: "c1")
        XCTAssertEqual(seen.map { "\($0.0) \($0.1)" }, ["POST /categories", "PATCH /categories/c1", "DELETE /categories/c1"])
        XCTAssertEqual(seen[0].2 as? [String: String], ["name": "读书", "color": "red"])
        XCTAssertEqual(seen[1].2 as? [String: String], ["name": "读书"])
    }

    func testTasksDecodesAndSendsBearerToken() async throws {
        var captured: URLRequest?
        StubURLProtocol.handler = { req in
            captured = req
            return (200, Data(#"{"tasks":[{"id":"t1","content":"写周报","projectId":"p1","priority":4,"dueDate":"2026-10-24","isRecurring":true}]}"#.utf8))
        }
        let tasks = try await makeClient().tasks(filter: .today)
        XCTAssertEqual(tasks, [TodoistTask(id: "t1", content: "写周报", projectId: "p1", priority: 4, dueDate: "2026-10-24", isRecurring: true)])
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(captured?.url?.path, "/todoist/tasks")
        XCTAssertEqual(captured?.url?.query, "filter=today")
    }

    func testNullDueDateDecodes() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"tasks":[{"id":"t","content":"c","projectId":"p","priority":1,"dueDate":null,"isRecurring":false}]}"#.utf8))
        }
        let tasks = try await makeClient().tasks(filter: .overdue)
        XCTAssertNil(tasks[0].dueDate)
    }

    func testCategoriesDecodeWithNullTodoistProjectId() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"categories":[{"id":"c1","name":"工作","color":"blue","todoistProjectId":"p1"},{"id":"c2","name":"自定义","color":"red","todoistProjectId":null}]}"#.utf8))
        }
        let cats = try await makeClient().categories()
        XCTAssertEqual(cats.map(\.id), ["c1", "c2"])
        XCTAssertEqual(cats[0].todoistProjectId, "p1")
        XCTAssertNil(cats[1].todoistProjectId)
    }

    func testEntriesDecode() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"entries":[{"id":"e1","title":"a","categoryId":"c1"},{"id":"e2","title":"b","categoryId":null}]}"#.utf8))
        }
        let entries = try await makeClient().entries()
        XCTAssertEqual(entries, [Entry(id: "e1", title: "a", categoryId: "c1"), Entry(id: "e2", title: "b", categoryId: nil)])
    }

    func testErrorCodeIsSurfaced() async {
        StubURLProtocol.handler = { _ in (401, Data(#"{"error":"TODOIST_AUTH"}"#.utf8)) }
        do {
            _ = try await makeClient().tasks(filter: .today)
            XCTFail("should throw")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 401, code: "TODOIST_AUTH"))
        } catch { XCTFail("wrong error \(error)") }
    }

    func testNonJSONErrorBodyGivesNilCode() async {
        StubURLProtocol.handler = { _ in (502, Data("<html>Bad Gateway</html>".utf8)) }
        do {
            _ = try await makeClient().entries()
            XCTFail("should throw")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 502, code: nil))
        } catch { XCTFail("wrong error \(error)") }
    }

    func testMalformedSuccessBodyThrowsDecodingError() async {
        StubURLProtocol.handler = { _ in (200, Data("not json".utf8)) }
        do {
            _ = try await makeClient().tasks(filter: .today)
            XCTFail("should throw")
        } catch is DecodingError {
            // expected
        } catch { XCTFail("wrong error \(error)") }
    }

    func testTransportFailureThrowsTransportError() async {
        // 没有 handler：stub 以 URLError 失败。
        do {
            _ = try await makeClient().entries()
            XCTFail("should throw")
        } catch let error as APIError {
            guard case .transport = error else { return XCTFail("wrong case \(error)") }
        } catch { XCTFail("wrong error \(error)") }
    }

    func testCreateEntryPostsJSON() async throws {
        var captured: URLRequest?
        var body: [String: Any]?
        StubURLProtocol.handler = { req in
            captured = req
            body = (try? JSONSerialization.jsonObject(with: bodyData(of: req))) as? [String: Any]
            return (200, Data(#"{"entry":{"id":"e1","title":"读论文","categoryId":null}}"#.utf8))
        }
        let entry = try await makeClient().createEntry(title: "读论文", categoryId: nil)
        XCTAssertEqual(entry, Entry(id: "e1", title: "读论文", categoryId: nil))
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(body?["title"] as? String, "读论文")
        XCTAssertTrue(body?.keys.contains("categoryId") == true)   // null 必须显式发送，后端要求该字段存在
        XCTAssertTrue(body?["categoryId"] is NSNull)
    }

    func testCreateEntrySendsCategoryId() async throws {
        var body: [String: Any]?
        StubURLProtocol.handler = { req in
            body = (try? JSONSerialization.jsonObject(with: bodyData(of: req))) as? [String: Any]
            return (200, Data(#"{"entry":{"id":"e1","title":"t","categoryId":"c1"}}"#.utf8))
        }
        _ = try await makeClient().createEntry(title: "t", categoryId: "c1")
        XCTAssertEqual(body?["categoryId"] as? String, "c1")
    }

    func testSyncSessionsSendsMillisecondsAndNullsAndDecodesResult() async throws {
        var captured: URLRequest?
        var body: [String: Any]?
        StubURLProtocol.handler = { req in
            captured = req
            body = (try? JSONSerialization.jsonObject(with: bodyData(of: req))) as? [String: Any]
            return (200, Data(#"{"accepted":["s1"],"rejected":[{"id":"s2","reason":"CONFLICT"}]}"#.utf8))
        }
        let rec = SessionRecord(id: "s1", title: "写周报", categoryId: nil, source: .custom, todoistTaskId: nil,
                                entryId: nil, plannedSeconds: 1500, actualSeconds: 1500,
                                startedAt: Date(timeIntervalSince1970: 1_761_300_000), endedAt: Date(timeIntervalSince1970: 1_761_301_500),
                                allowIdle: true)
        let span = ActivitySpan(id: "p1", sessionId: "s1", kind: .active, appBundleId: "com.apple.dt.Xcode", appName: "Xcode",
                                windowTitle: nil, urlHost: nil, startedAt: Date(timeIntervalSince1970: 1_761_300_000),
                                endedAt: Date(timeIntervalSince1970: 1_761_300_060), wasBlocked: true)
        let result = try await makeClient().syncSessions([(rec, [span])])

        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.path, "/sync/sessions")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let sessions = body?["sessions"] as? [[String: Any]]
        XCTAssertEqual((sessions?[0]["startedAt"] as? NSNumber)?.int64Value, 1_761_300_000_000)
        XCTAssertTrue(sessions?[0]["categoryId"] is NSNull)
        XCTAssertEqual(sessions?[0]["allowIdle"] as? Bool, true)
        let spans = sessions?[0]["spans"] as? [[String: Any]]
        XCTAssertEqual(spans?[0]["wasBlocked"] as? Bool, true)
        XCTAssertTrue(spans?[0]["windowTitle"] is NSNull)
        XCTAssertEqual(result, SyncResult(accepted: ["s1"], rejected: [.init(id: "s2", reason: "CONFLICT")]))
    }
}

final class APIClientEvaluationTests: XCTestCase {
    override func setUp() { super.setUp(); StubURLProtocol.handler = nil }
    override func tearDown() { StubURLProtocol.handler = nil; super.tearDown() }

    func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return APIClient(baseURL: URL(string: "http://localhost:8787")!, token: "tok", session: URLSession(configuration: config))
    }

    func testSessionsSendsMillisecondRangeAndDecodesEvaluations() async throws {
        var captured: URLRequest?
        StubURLProtocol.handler = { req in
            captured = req
            return (200, Data("""
            {"sessions":[
             {"id":"s1","categoryId":null,"source":"custom","todoistTaskId":null,"entryId":null,"title":"写周报",
              "plannedSeconds":1500,"actualSeconds":1500,"startedAt":1761300000000,"endedAt":1761301500000,
              "evaluation":{"status":"done","focusScore":82,"summary":"专注","attempts":1,
                            "distractions":[{"start":1761300600000,"end":1761300660000,"reason":"刷微博"}]}},
             {"id":"s2","categoryId":"c1","source":"todoist","todoistTaskId":"t","entryId":null,"title":"b",
              "plannedSeconds":1500,"actualSeconds":600,"startedAt":1761302000000,"endedAt":1761302600000,
              "evaluation":{"status":"pending","focusScore":null,"summary":null,"distractions":[],"attempts":0}},
             {"id":"s3","categoryId":null,"source":"custom","todoistTaskId":null,"entryId":null,"title":"c",
              "plannedSeconds":1500,"actualSeconds":600,"startedAt":1761303000000,"endedAt":1761303600000,"evaluation":null}
            ]}
            """.utf8))
        }
        let from = Date(timeIntervalSince1970: 1_761_264_000), to = Date(timeIntervalSince1970: 1_761_350_400)
        let sessions = try await makeClient().sessions(from: from, to: to)

        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.url?.path, "/sessions")
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "from", value: "1761264000000"), URLQueryItem(name: "to", value: "1761350400000")])
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(sessions.map(\.id), ["s1", "s2", "s3"])
        XCTAssertEqual(sessions[0].startedAt, Date(timeIntervalSince1970: 1_761_300_000))
        XCTAssertEqual(sessions[0].evaluation, Evaluation(
            status: .done, focusScore: 82, summary: "专注", attempts: 1,
            distractions: [.init(start: Date(timeIntervalSince1970: 1_761_300_600),
                                 end: Date(timeIntervalSince1970: 1_761_300_660), reason: "刷微博")]))
        XCTAssertEqual(sessions[1].evaluation?.status, .pending)
        XCTAssertNil(sessions[1].evaluation?.focusScore)
        XCTAssertNil(sessions[2].evaluation)
    }

    func testRetryEvaluationPostsToSessionPath() async throws {
        var captured: URLRequest?
        StubURLProtocol.handler = { req in captured = req; return (202, Data(#"{"status":"pending"}"#.utf8)) }
        try await makeClient().retryEvaluation(id: "s1")
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.path, "/evaluations/s1/retry")
    }

    func testRetryEvaluationNotFoundThrows() async {
        StubURLProtocol.handler = { _ in (404, Data(#"{"error":"NOT_FOUND"}"#.utf8)) }
        do {
            try await makeClient().retryEvaluation(id: "x")
            XCTFail("should throw")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 404, code: "NOT_FOUND"))
        } catch { XCTFail("wrong error \(error)") }
    }

    func testStatsSendsRangeAndTimezoneAndDecodes() async throws {
        var captured: URLRequest?
        StubURLProtocol.handler = { req in
            captured = req
            return (200, Data("""
            {"totalFocusSeconds":3000,"sessionCount":2,"avgFocusScore":null,"activeSeconds":2400,"idleSeconds":600,
             "days":[{"date":"2026-10-25","focusSeconds":3000,"sessionCount":2,"avgFocusScore":null},
                     {"date":"2026-10-26","focusSeconds":0,"sessionCount":0,"avgFocusScore":75}],
             "byCategory":[{"categoryId":"c1","focusSeconds":2000},{"categoryId":null,"focusSeconds":1000}]}
            """.utf8))
        }
        let stats = try await makeClient().stats(from: Date(timeIntervalSince1970: 1_761_264_000),
                                                 to: Date(timeIntervalSince1970: 1_761_350_400), tzOffsetMinutes: 480)
        XCTAssertEqual(captured?.url?.path, "/stats")
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "from", value: "1761264000000"), URLQueryItem(name: "to", value: "1761350400000"),
            URLQueryItem(name: "tzOffsetMinutes", value: "480"),
        ])
        let withTZ = try await makeClient().stats(from: Date(timeIntervalSince1970: 1_761_264_000),
                                                  to: Date(timeIntervalSince1970: 1_761_350_400), tzOffsetMinutes: 0,
                                                  timeZone: TimeZone(identifier: "Europe/London"))
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems?.last,
                       URLQueryItem(name: "tz", value: "Europe/London"))
        XCTAssertEqual(withTZ.totalFocusSeconds, 3000)
        XCTAssertEqual(stats.totalFocusSeconds, 3000)
        XCTAssertNil(stats.avgFocusScore)
        XCTAssertEqual(stats.idleSeconds, 600)
        XCTAssertEqual(stats.days.map(\.date), ["2026-10-25", "2026-10-26"])
        XCTAssertEqual(stats.days[1].avgFocusScore, 75)
        XCTAssertEqual(stats.byCategory.map(\.categoryId), ["c1", nil])
    }

    func testSettingsDecode() async throws {
        var captured: URLRequest?
        StubURLProtocol.handler = { req in
            captured = req
            return (200, Data(#"{"focusSeconds":1500,"idleThresholdSeconds":120,"blockApps":["com.a"],"blockDomains":["youtube.com"]}"#.utf8))
        }
        let s = try await makeClient().settings()
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.url?.path, "/settings")
        XCTAssertEqual(s, RemoteSettings(focusSeconds: 1500, idleThresholdSeconds: 120,
                                         blockApps: ["com.a"], blockDomains: ["youtube.com"]))
    }

    func testUpdateSettingsSendsOnlyProvidedFields() async throws {
        var captured: URLRequest?
        var body: [String: Any]?
        StubURLProtocol.handler = { req in
            captured = req
            body = (try? JSONSerialization.jsonObject(with: bodyData(of: req))) as? [String: Any]
            return (200, Data(#"{"focusSeconds":600,"idleThresholdSeconds":120,"blockApps":[],"blockDomains":["a.com"]}"#.utf8))
        }
        let merged = try await makeClient().updateSettings(SettingsPatch(focusSeconds: 600, blockDomains: ["A.com"]))
        XCTAssertEqual(captured?.httpMethod, "PUT")
        XCTAssertEqual(captured?.url?.path, "/settings")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(Set(body?.keys ?? [:].keys), ["focusSeconds", "blockDomains"])
        XCTAssertEqual(body?["focusSeconds"] as? Int, 600)
        XCTAssertEqual(body?["blockDomains"] as? [String], ["A.com"])
        XCTAssertEqual(merged.blockDomains, ["a.com"])
    }
}

final class TodoistTaskDueTimeTests: XCTestCase {
    private func task(_ due: String?) -> TodoistTask {
        TodoistTask(id: "t", content: "c", projectId: "p", priority: 1, dueDate: due, isRecurring: false)
    }

    func testDateOnlyHasNoDueTime() { XCTAssertNil(task("2026-10-25").dueTime) }
    func testNoDueHasNoDueTime() { XCTAssertNil(task(nil).dueTime) }

    func testFloatingTimeIsLocal() {
        let t = task("2026-10-25T15:15:00").dueTime!
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: t)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2026, 10, 25, 15, 15])
    }

    func testUtcTime() {
        XCTAssertEqual(task("2026-10-25T07:15:00Z").dueTime, Date(timeIntervalSince1970: 1_792_912_500))
    }
}
