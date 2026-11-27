import AppKit
import CryptoKit
import Foundation
import Network

// Cloud sync: Google sign-in → Firebase Auth → Firestore (REST, no SDK).
// The Mac that runs the helper uploads (helper/brokerd/cloud.py); any Mac signed in to the same Google
// account reads users/{uid}/state/* when it has no helper of its own.

/// Bundled at build time from app/Brokers/cloud-config.json (gitignored; see cloud-config.example.json).
struct CloudConfig: Codable {
    var apiKey: String
    var projectId: String
    var googleClientId: String
    var googleClientSecret: String

    static let shared: CloudConfig? = {
        guard let url = Bundle.main.url(forResource: "cloud-config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(CloudConfig.self, from: data),
              !c.apiKey.isEmpty, !c.projectId.isEmpty, !c.googleClientId.isEmpty
        else { return nil }
        return c
    }()
}

/// Firebase session shared with the helper through ~/Library/Application Support/Brokers/cloud.json (0600).
struct CloudSession: Codable, Equatable {
    var apiKey: String
    var projectId: String
    var uid: String
    var email: String?
    var refreshToken: String

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Brokers/cloud.json")

    static func load() -> CloudSession? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CloudSession.self, from: d)
    }

    func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = Self.url.appendingPathExtension("tmp")
        fm.createFile(atPath: tmp.path, contents: try JSONEncoder().encode(self), attributes: [.posixPermissions: 0o600])
        _ = try fm.replaceItemAt(Self.url, withItemAt: tmp)
    }

    static func delete() { try? FileManager.default.removeItem(at: url) }
}

enum CloudError: LocalizedError {
    case notConfigured, timeout, denied(String), http(Int, String), noData

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "클라우드 설정(cloud-config.json)이 앱에 없어요"
        case .timeout: return "로그인 시간이 초과됐어요"
        case let .denied(m): return "로그인 취소됨 (\(m))"
        case let .http(code, body): return "클라우드 오류 \(code): \(Self.message(body))"
        case .noData: return "아직 올라온 데이터가 없어요 — 데이터를 모으는 Mac에서도 같은 계정으로 로그인하세요"
        }
    }

    private static func message(_ body: String) -> String {
        if let d = body.data(using: .utf8),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let e = j["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let m = j["error_description"] as? String { return m }
        }
        return String(body.prefix(200))
    }
}

/// A Firestore document's fields (we only use strings and timestamps).
struct CloudDoc {
    let fields: [String: Any]

    func string(_ k: String) -> String? { (fields[k] as? [String: Any])?["stringValue"] as? String }
    func date(_ k: String) -> Date? { ((fields[k] as? [String: Any])?["timestampValue"] as? String).flatMap(ISODate.parse) }
    func decode<T: Decodable>(_ type: T.Type, _ k: String) -> T? {
        string(k).flatMap { try? ISODate.decoder.decode(T.self, from: Data($0.utf8)) }
    }
}

actor CloudClient {
    static let shared = CloudClient()
    private var token: (value: String, expires: Date, refresh: String)?
    private let http = URLSession(configuration: .ephemeral)

    private func idToken(_ s: CloudSession) async throws -> String {
        if let t = token, t.refresh == s.refreshToken, t.expires > Date().addingTimeInterval(120) { return t.value }
        var req = URLRequest(url: URL(string: "https://securetoken.googleapis.com/v1/token?key=\(s.apiKey)")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = FormHTTP.encode(["grant_type": "refresh_token", "refresh_token": s.refreshToken])
        let j = try await FormHTTP.json(http, req)
        guard let v = j["id_token"] as? String else { throw CloudError.http(0, "no id_token") }
        let ttl = Double(j["expires_in"] as? String ?? "3600") ?? 3600
        token = (v, Date().addingTimeInterval(ttl), s.refreshToken)
        return v
    }

    private func docURL(_ s: CloudSession, _ path: String) -> URL {
        URL(string: "https://firestore.googleapis.com/v1/projects/\(s.projectId)/databases/(default)/documents/users/\(s.uid)/\(path)")!
    }

    /// nil when the document doesn't exist yet.
    func get(_ s: CloudSession, _ path: String) async throws -> CloudDoc? {
        var req = URLRequest(url: docURL(s, path))
        req.setValue("Bearer \(try await idToken(s))", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await http.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200 else { throw CloudError.http(code, String(data: data, encoding: .utf8) ?? "") }
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return CloudDoc(fields: j?["fields"] as? [String: Any] ?? [:])
    }

    func put(_ s: CloudSession, _ path: String, strings: [String: String]) async throws {
        var fields: [String: Any] = strings.mapValues { ["stringValue": $0] }
        fields["updated"] = ["timestampValue": ISO8601DateFormatter().string(from: Date())]
        var req = URLRequest(url: docURL(s, path))
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(try await idToken(s))", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields])
        _ = try await FormHTTP.json(http, req)
    }

    /// Upsert with mixed fields: String → stringValue, numbers → doubleValue.
    func put(_ s: CloudSession, _ path: String, fields values: [String: Any]) async throws {
        var fields: [String: Any] = [:]
        for (k, v) in values {
            if let x = v as? String { fields[k] = ["stringValue": x] }
            else if let x = v as? Double { fields[k] = ["doubleValue": x] }
            else if let x = v as? Int { fields[k] = ["doubleValue": Double(x)] }
        }
        fields["updated"] = ["timestampValue": ISO8601DateFormatter().string(from: Date())]
        var req = URLRequest(url: docURL(s, path))
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(try await idToken(s))", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields])
        _ = try await FormHTTP.json(http, req)
    }

    func delete(_ s: CloudSession, _ path: String) async throws {
        var req = URLRequest(url: docURL(s, path))
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(try await idToken(s))", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await http.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 404 else { throw CloudError.http(code, String(data: data, encoding: .utf8) ?? "") }
    }

    func reset() { token = nil }
}

enum FormHTTP {
    static func encode(_ v: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(v.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
    }

    static func json(_ http: URLSession, _ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await http.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw CloudError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

// MARK: - Google sign-in (OAuth 2.0 for desktop apps: loopback redirect + PKCE)

enum GoogleSignIn {
    static func signIn(_ cfg: CloudConfig) async throws -> CloudSession {
        let server = try LoopbackServer()
        defer { server.stop() }
        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)"
        let verifier = randomURLSafe(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = randomURLSafe(16)

        var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        auth.queryItems = [
            .init(name: "client_id", value: cfg.googleClientId),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "prompt", value: "select_account"),
        ]
        NSWorkspace.shared.open(auth.url!)

        let q = try await server.waitForCallback(timeout: 300)
        func item(_ n: String) -> String? { q.first { $0.name == n }?.value }
        if let e = item("error") { throw CloudError.denied(e) }
        guard item("state") == state, let code = item("code") else { throw CloudError.denied("state mismatch") }

        let http = URLSession(configuration: .ephemeral)
        var tok = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        tok.httpMethod = "POST"
        tok.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        tok.httpBody = FormHTTP.encode([
            "code": code, "client_id": cfg.googleClientId, "client_secret": cfg.googleClientSecret,
            "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        guard let googleID = try await FormHTTP.json(http, tok)["id_token"] as? String else {
            throw CloudError.http(0, "Google이 id_token을 주지 않았어요")
        }

        var fb = URLRequest(url: URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=\(cfg.apiKey)")!)
        fb.httpMethod = "POST"
        fb.setValue("application/json", forHTTPHeaderField: "Content-Type")
        fb.httpBody = try JSONSerialization.data(withJSONObject: [
            "postBody": "id_token=\(googleID)&providerId=google.com",
            "requestUri": "http://localhost",
            "returnSecureToken": true,
            "returnIdpCredential": true,
        ])
        let j = try await FormHTTP.json(http, fb)
        guard let uid = j["localId"] as? String, let refresh = j["refreshToken"] as? String else {
            throw CloudError.http(0, "Firebase 로그인 응답이 이상해요")
        }
        return CloudSession(apiKey: cfg.apiKey, projectId: cfg.projectId, uid: uid,
                            email: j["email"] as? String, refreshToken: refresh)
    }

    private static func randomURLSafe(_ n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One-shot HTTP listener on 127.0.0.1 that catches the OAuth redirect.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "money.oauth-loopback")
    private var waiter: CheckedContinuation<[URLQueryItem], Error>?
    private var result: Result<[URLQueryItem], Error>?

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var done = false
            listener.stateUpdateHandler = { [weak self] st in
                guard !done else { return }
                switch st {
                case .ready: done = true; cont.resume(returning: self?.listener.port?.rawValue ?? 0)
                case let .failed(e): done = true; cont.resume(throwing: e)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] c in self?.handle(c) }
            listener.start(queue: queue)
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [URLQueryItem] {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(CloudError.timeout)) }
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let r = self.result { cont.resume(with: r) } else { self.waiter = cont }
            }
        }
    }

    func stop() { listener.cancel() }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, _, _ in
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let comps = URLComponents(string: "http://127.0.0.1\(target)")
            let items = comps?.queryItems ?? []
            let isCallback = comps?.path == "/" && items.contains { $0.name == "code" || $0.name == "error" }
            let ok = items.contains { $0.name == "code" }
            let html = isCallback ? Self.page(ok: ok) : "not found"
            let head = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data((head + html).utf8), completion: .contentProcessed { _ in c.cancel() })
            if isCallback { self?.finish(.success(items)) }
        }
    }

    /// Browser page shown after Google redirects back. Matches the app icon (mint + dark green "m").
    static func page(ok: Bool) -> String {
        let title = ok ? "You're signed in" : "Sign-in cancelled"
        let body = ok ? "You can close this tab and return to money."
                      : "Nothing was changed. Return to money and try again."
        let badge = ok
            ? #"<path d="M5 12.5l4.5 4.5L19 7.5" />"#
            : #"<path d="M7 7l10 10M17 7L7 17" />"#
        return #"""
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>money — \#(title)</title>
        <style>
        :root{--bg:#f4f8f5;--card:#fff;--ink:#0f1f16;--sub:#5b6b61;--line:#e3ebe6;--mint:#E6F6EC;--mint2:#BFE5CD;--green:#166534;--ok:#16a34a;--bad:#b45309}
        @media (prefers-color-scheme:dark){:root{--bg:#0d1410;--card:#151e18;--ink:#e8f1eb;--sub:#94a69b;--line:#24302a}}
        *{box-sizing:border-box;margin:0}
        body{min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--ink);
          font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif;-webkit-font-smoothing:antialiased;padding:24px}
        .card{width:100%;max-width:380px;background:var(--card);border:1px solid var(--line);border-radius:20px;
          padding:40px 32px 32px;text-align:center;box-shadow:0 1px 2px rgba(0,0,0,.04),0 12px 32px rgba(22,101,52,.08)}
        .icon{position:relative;width:72px;height:72px;margin:0 auto 24px;border-radius:17px;
          background:linear-gradient(180deg,var(--mint),var(--mint2));display:grid;place-items:center;
          box-shadow:0 6px 16px rgba(22,101,52,.18)}
        .icon span{font:600 46px/1 "SF Pro Rounded",ui-rounded,-apple-system,sans-serif;color:var(--green);margin-top:-6px}
        .badge{position:absolute;right:-8px;bottom:-8px;width:28px;height:28px;border-radius:50%;
          background:\#(ok ? "var(--ok)" : "var(--bad)");border:3px solid var(--card);display:grid;place-items:center}
        .badge svg{width:14px;height:14px;fill:none;stroke:#fff;stroke-width:3;stroke-linecap:round;stroke-linejoin:round}
        h1{font-size:21px;font-weight:650;letter-spacing:-.01em;margin-bottom:6px}
        p{color:var(--sub)}
        .foot{margin-top:28px;padding-top:16px;border-top:1px solid var(--line);font-size:12px;color:var(--sub)}
        </style></head><body>
        <main class="card">
          <div class="icon"><span>m</span><div class="badge"><svg viewBox="0 0 24 24">\#(badge)</svg></div></div>
          <h1>\#(title)</h1>
          <p>\#(body)</p>
          <div class="foot">money · portfolio sync</div>
        </main></body></html>
        """#
    }

    private func finish(_ r: Result<[URLQueryItem], Error>) {
        queue.async {
            guard self.result == nil else { return }
            self.result = r
            if let w = self.waiter { self.waiter = nil; w.resume(with: r) }
        }
    }
}
