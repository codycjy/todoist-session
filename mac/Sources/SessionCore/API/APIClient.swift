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
