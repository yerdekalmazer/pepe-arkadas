import AppKit
import CryptoKit
import Network

/// MCP yetkilendirme akışı (OAuth 2.1): korunan kaynak meta verisi → yetki sunucusu meta verisi →
/// dinamik istemci kaydı → PKCE ile tarayıcıda giriş → 127.0.0.1'e dönüş → jeton. Jetonlar Keychain'de.
enum MCPOAuth {
    static let callbackPort: UInt16 = 47824
    static var redirectURI: String { "http://127.0.0.1:\(callbackPort)/callback" }

    struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var tokenEndpoint: String
        var clientId: String
        var clientSecret: String?
        var resource: String
    }

    enum Failure: LocalizedError {
        case discovery(String), registration(String), denied(String), token(String)
        var errorDescription: String? {
            switch self {
            case .discovery(let m): "Yetki sunucusu bulunamadı: \(m)"
            case .registration(let m): "Serçe bu sunucuya kaydolamadı: \(m)"
            case .denied(let m): "Giriş tamamlanmadı: \(m)"
            case .token(let m): "Jeton alınamadı: \(m)"
            }
        }
    }

    private static func key(_ serverId: String) -> String { "mcp.oauth.\(serverId)" }

    static func stored(_ serverId: String) -> Tokens? {
        guard let s = Keychain.get(key(serverId)), let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: d)
    }

    static func store(_ t: Tokens?, _ serverId: String) {
        guard let t, let d = try? JSONEncoder().encode(t) else { Keychain.set(key(serverId), nil); return }
        Keychain.set(key(serverId), String(data: d, encoding: .utf8))
    }

    /// Geçerli erişim jetonu; süresi dolmak üzereyse yeniler. Yoksa nil (giriş gerekir).
    static func accessToken(_ serverId: String) async -> String? {
        guard var t = stored(serverId) else { return nil }
        if let exp = t.expiresAt, exp.timeIntervalSinceNow < 60 {
            guard let refreshed = try? await refresh(t) else { return nil }
            t = refreshed
            store(t, serverId)
        }
        return t.accessToken
    }

    // MARK: - Giriş

    static func signIn(serverId: String, resource: URL, wwwAuthenticate: String?) async throws {
        let asMeta = try await discover(resource: resource, wwwAuthenticate: wwwAuthenticate)
        guard let authEndpoint = asMeta["authorization_endpoint"] as? String,
              let tokenEndpoint = asMeta["token_endpoint"] as? String else { throw Failure.discovery("uç noktalar eksik") }
        let (clientId, clientSecret) = try await register(asMeta)

        let verifier = randomString(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = randomString(24)
        var c = URLComponents(string: authEndpoint)!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: resource.absoluteString),
        ]
        if let scopes = asMeta["scopes_supported"] as? [String], !scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
        }
        c.queryItems = (c.queryItems ?? []) + items

        let code = try await CallbackServer.waitForCode(state: state) {
            NSWorkspace.shared.open(c.url!)
        }

        var form = ["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
                    "client_id": clientId, "code_verifier": verifier, "resource": resource.absoluteString]
        if let clientSecret { form["client_secret"] = clientSecret }
        let json = try await postForm(tokenEndpoint, form)
        guard let access = json["access_token"] as? String else { throw Failure.token(json["error_description"] as? String ?? "yanıt boş") }
        store(Tokens(accessToken: access, refreshToken: json["refresh_token"] as? String,
                     expiresAt: (json["expires_in"] as? Double).map { Date().addingTimeInterval($0) },
                     tokenEndpoint: tokenEndpoint, clientId: clientId, clientSecret: clientSecret,
                     resource: resource.absoluteString), serverId)
    }

    static func signOut(_ serverId: String) { store(nil, serverId) }

    /// Test için: tarayıcı açmadan keşif adımını dener, yetki sunucusu ve kayıt desteğini döner.
    static func probe(resource: URL, wwwAuthenticate: String?) async -> String {
        do {
            let m = try await discover(resource: resource, wwwAuthenticate: wwwAuthenticate)
            let reg = m["registration_endpoint"] != nil ? "dinamik kayıt var" : "dinamik kayıt YOK"
            return "yetki: \(URL(string: m["authorization_endpoint"] as? String ?? "")?.host ?? "?") · \(reg)"
        } catch {
            return "keşif başarısız: \(error.localizedDescription)"
        }
    }

    private static func refresh(_ t: Tokens) async throws -> Tokens {
        guard let rt = t.refreshToken else { throw Failure.token("yenileme jetonu yok") }
        var form = ["grant_type": "refresh_token", "refresh_token": rt, "client_id": t.clientId, "resource": t.resource]
        if let s = t.clientSecret { form["client_secret"] = s }
        let json = try await postForm(t.tokenEndpoint, form)
        guard let access = json["access_token"] as? String else { throw Failure.token("yenilenemedi") }
        var n = t
        n.accessToken = access
        n.refreshToken = json["refresh_token"] as? String ?? rt
        n.expiresAt = (json["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
        return n
    }

    // MARK: - Keşif ve kayıt

    private static func discover(resource: URL, wwwAuthenticate: String?) async throws -> [String: Any] {
        var candidates: [URL] = []
        if let h = wwwAuthenticate, let r = h.range(of: "resource_metadata=\"") {
            let rest = h[r.upperBound...]
            if let end = rest.firstIndex(of: "\""), let u = URL(string: String(rest[..<end])) { candidates.append(u) }
        }
        let origin = URL(string: "\(resource.scheme ?? "https")://\(resource.host ?? "")\(resource.port.map { ":\($0)" } ?? "")")!
        let path = resource.path == "/" ? "" : resource.path
        candidates.append(origin.appendingPathComponent(".well-known/oauth-protected-resource" + path))
        candidates.append(origin.appendingPathComponent(".well-known/oauth-protected-resource"))

        var authServer = origin
        for u in candidates {
            if let meta = try? await getJSON(u), let s = (meta["authorization_servers"] as? [String])?.first, let su = URL(string: s) {
                authServer = su
                break
            }
        }
        let asPath = authServer.path == "/" ? "" : authServer.path
        let asOrigin = URL(string: "\(authServer.scheme ?? "https")://\(authServer.host ?? "")\(authServer.port.map { ":\($0)" } ?? "")")!
        for wk in ["oauth-authorization-server", "openid-configuration"] {
            for u in [asOrigin.appendingPathComponent(".well-known/\(wk)" + asPath), authServer.appendingPathComponent(".well-known/\(wk)")] {
                if let meta = try? await getJSON(u), meta["authorization_endpoint"] != nil { return meta }
            }
        }
        throw Failure.discovery(authServer.absoluteString)
    }

    /// Dinamik istemci kaydı (RFC 7591). Aynı sunucu için istemci kimliği saklanır, her girişte yeniden kaydolunmaz.
    private static func register(_ meta: [String: Any]) async throws -> (String, String?) {
        guard let endpoint = meta["registration_endpoint"] as? String else {
            throw Failure.registration("sunucu dinamik kaydı desteklemiyor")
        }
        let cacheKey = "mcp.client.\(endpoint)"
        if let cached = Keychain.get(cacheKey), let d = cached.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: String], let id = obj["id"] {
            return (id, obj["secret"])
        }
        var r = URLRequest(url: URL(string: endpoint)!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "Serçe",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = json["client_id"] as? String else {
            throw Failure.registration("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let secret = json["client_secret"] as? String
        var store = ["id": id]
        if let secret { store["secret"] = secret }
        if let d = try? JSONSerialization.data(withJSONObject: store) { Keychain.set(cacheKey, String(data: d, encoding: .utf8)) }
        return (id, secret)
    }

    // MARK: - HTTP yardımcıları

    private static func getJSON(_ url: URL) async throws -> [String: Any] {
        var r = URLRequest(url: url)
        r.timeoutInterval = 15
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.discovery(url.absoluteString) }
        return json
    }

    private static func postForm(_ endpoint: String, _ form: [String: String]) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: endpoint)!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        r.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: r)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func randomString(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes).base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Tarayıcıdan dönen yetki kodunu 127.0.0.1:47824'te bekler (tek kullanımlık, 5 dk).
private final class CallbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let state: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?

    private init(state: String) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: MCPOAuth.callbackPort)!)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        self.state = state
    }

    static func waitForCode(state: String, open: @escaping @MainActor () -> Void) async throws -> String {
        let server = try CallbackServer(state: state)
        return try await withCheckedThrowingContinuation { c in
            server.continuation = c
            server.listener.newConnectionHandler = { conn in server.handle(conn) }
            server.listener.start(queue: .global())
            Task { @MainActor in open() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
                server.finish(.failure(MCPOAuth.Failure.denied("5 dakika içinde tamamlanmadı")))
            }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8),
                  let line = req.components(separatedBy: "\r\n").first else { conn.cancel(); return }
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let items = URLComponents(string: "http://x" + path)?.queryItems ?? []
            let q = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            let ok = q["code"] != nil && q["state"] == self.state
            let html = ok
                ? "<h2 style='font-family:-apple-system'>Serçe'ye bağlandı ✓</h2><p style='font-family:-apple-system'>Bu sekmeyi kapatabilirsin.</p>"
                : "<h2 style='font-family:-apple-system'>Bağlantı tamamlanmadı</h2><p style='font-family:-apple-system'>\(q["error_description"] ?? q["error"] ?? "")</p>"
            let body = Data(html.utf8)
            var resp = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            resp.append(body)
            conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
            if path.hasPrefix("/callback") {
                if ok, let code = q["code"] { self.finish(.success(code)) }
                else { self.finish(.failure(MCPOAuth.Failure.denied(q["error_description"] ?? q["error"] ?? "geçersiz yanıt"))) }
            }
        }
    }

    private func finish(_ r: Result<String, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c else { return }
        listener.cancel()
        c.resume(with: r)
    }
}
