import Foundation

public enum APIError: Error, Equatable {
    case server(status: Int, code: String?)
    case transport(String)
}

private struct ErrorBody: Decodable { let error: String? }

public final class APIClient: @unchecked Sendable {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL; self.token = token; self.session = session
    }

    public func tasks(filter: TaskFilter) async throws -> [TodoistTask] {
        struct R: Decodable { let tasks: [TodoistTask] }
        let r: R = try await send("GET", "/todoist/tasks", query: [URLQueryItem(name: "filter", value: filter.rawValue)])
        return r.tasks
    }

    public func syncProjects() async throws -> [Category] {
        struct R: Decodable { let categories: [Category] }
        return (try await send("GET", "/todoist/projects") as R).categories
    }

    public func categories() async throws -> [Category] {
        struct R: Decodable { let categories: [Category] }
        return (try await send("GET", "/categories") as R).categories
    }

    /// 含已归档分类（历史 session 的名称/颜色查找用）。
    public func allCategories() async throws -> [Category] {
        struct R: Decodable { let categories: [Category] }
        return (try await send("GET", "/categories", query: [URLQueryItem(name: "all", value: "1")]) as R).categories
    }

    public func entries() async throws -> [Entry] {
        struct R: Decodable { let entries: [Entry] }
        return (try await send("GET", "/entries") as R).entries
    }

    public func createEntry(title: String, categoryId: String?) async throws -> Entry {
        struct R: Decodable { let entry: Entry }
        // 手写 JSON：Codable 默认会省略 nil，而后端要求 categoryId 字段存在（可为 null）。
        var payload: [String: Any] = ["title": title]
        payload["categoryId"] = categoryId ?? NSNull()
        let body = try JSONSerialization.data(withJSONObject: payload)
        return (try await send("POST", "/entries", body: body) as R).entry
    }

    public func syncSessions(_ batch: [(session: SessionRecord, spans: [ActivitySpan])]) async throws -> SyncResult {
        func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
        func orNull(_ s: String?) -> Any { s ?? NSNull() }
        let sessions: [[String: Any]] = batch.map { item in
            let s = item.session
            return [
                "id": s.id, "categoryId": orNull(s.categoryId), "source": s.source.rawValue,
                "todoistTaskId": orNull(s.todoistTaskId), "entryId": orNull(s.entryId),
                "title": s.title, "plannedSeconds": s.plannedSeconds, "actualSeconds": s.actualSeconds,
                "startedAt": ms(s.startedAt), "endedAt": ms(s.endedAt),
                "spans": item.spans.map { p -> [String: Any] in [
                    "id": p.id, "kind": p.kind.rawValue, "appBundleId": orNull(p.appBundleId),
                    "appName": orNull(p.appName), "windowTitle": orNull(p.windowTitle),
                    "urlHost": orNull(p.urlHost), "urlPath": orNull(p.urlPath),
                    "startedAt": ms(p.startedAt), "endedAt": ms(p.endedAt), "wasBlocked": p.wasBlocked,
                ] },
            ]
        }
        let body = try JSONSerialization.data(withJSONObject: ["sessions": sessions])
        return try await send("POST", "/sync/sessions", body: body)
    }

    public func sessions(from: Date, to: Date) async throws -> [RemoteSession] {
        struct R: Decodable { let sessions: [RemoteSession] }
        let r: R = try await send("GET", "/sessions", query: Self.rangeQuery(from: from, to: to))
        return r.sessions
    }

    public func retryEvaluation(id: String) async throws {
        struct R: Decodable { let status: String }
        _ = try await send("POST", "/evaluations/\(id)/retry") as R
    }

    public func stats(from: Date, to: Date, tzOffsetMinutes: Int) async throws -> StatsSummary {
        try await send("GET", "/stats", query: Self.rangeQuery(from: from, to: to)
                       + [URLQueryItem(name: "tzOffsetMinutes", value: String(tzOffsetMinutes))])
    }

    public func settings() async throws -> RemoteSettings {
        try await send("GET", "/settings")
    }

    public func updateSettings(_ patch: SettingsPatch) async throws -> RemoteSettings {
        try await send("PUT", "/settings", body: try JSONEncoder().encode(patch))
    }

    private static func rangeQuery(from: Date, to: Date) -> [URLQueryItem] {
        func ms(_ d: Date) -> String { String(Int64((d.timeIntervalSince1970 * 1000).rounded())) }
        return [URLQueryItem(name: "from", value: ms(from)), URLQueryItem(name: "to", value: ms(to))]
    }

    private func send<T: Decodable>(_ method: String, _ path: String,
                                    query: [URLQueryItem] = [], body: Data? = nil) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw APIError.transport("invalid URL: \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw APIError.transport(error.localizedDescription) }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.server(status: status, code: (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error)
        }
        // 解码失败直接抛出 DecodingError，不吞掉。
        return try JSONDecoder().decode(T.self, from: data)
    }
}
