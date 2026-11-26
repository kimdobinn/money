import Foundation

enum APIError: LocalizedError {
    case unreachable
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .unreachable: return "헬퍼(brokerd)에 연결할 수 없습니다"
        case let .http(code, body): return "헬퍼 오류 \(code): \(body)"
        }
    }
}

struct APIClient {
    static let base = URL(string: "http://127.0.0.1:8765")!

    var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30  // first chart load of a long history can take a few seconds
        return URLSession(configuration: c)
    }()

    /// Write token created by the helper. Only the (non-sandboxed) app can read it.
    static func writeToken() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Brokers/api-token")
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        var comps = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return try await send(URLRequest(url: comps.url!))
    }

    @discardableResult
    func write<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> T {
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var comps = URLComponents(url: Self.base.appendingPathComponent(parts[0]), resolvingAgainstBaseURL: false)!
        if parts.count > 1 { comps.percentEncodedQuery = parts[1] }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let tok = Self.writeToken() { req.setValue(tok, forHTTPHeaderField: "X-Brokers-Token") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return try await send(req)
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw APIError.unreachable
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw APIError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return try ISODate.decoder.decode(T.self, from: data)
    }
}

struct EmptyOK: Decodable {}
