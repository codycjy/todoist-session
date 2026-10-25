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
                                startedAt: Date(timeIntervalSince1970: 1_761_300_000), endedAt: Date(timeIntervalSince1970: 1_761_301_500))
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
        let spans = sessions?[0]["spans"] as? [[String: Any]]
        XCTAssertEqual(spans?[0]["wasBlocked"] as? Bool, true)
        XCTAssertTrue(spans?[0]["windowTitle"] is NSNull)
        XCTAssertEqual(result, SyncResult(accepted: ["s1"], rejected: [.init(id: "s2", reason: "CONFLICT")]))
    }
}
