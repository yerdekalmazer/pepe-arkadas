import Foundation

struct MCPTool: Identifiable {
    var id: String { name }
    let name: String
    let description: String
    let inputSchema: [String: Any]
    /// MCP araç işaretleri: salt okuma araçları onaysız çalışır.
    let readOnly: Bool
    let destructive: Bool
}

struct MCPToolResult {
    var text: String
    var images: [(mime: String, base64: String)] = []
    var isError: Bool
}

enum MCPError: LocalizedError {
    case needsAuth(wwwAuthenticate: String?)
    case http(Int, String)
    case rpc(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .needsAuth: "Giriş gerekli."
        case .http(let c, let m): "HTTP \(c)\(m.isEmpty ? "" : ": \(m.prefix(160))")"
        case .rpc(let m): m
        case .transport(let m): m
        }
    }
}

/// Tek bir MCP sunucusuna bağlantı: initialize → tools/list → tools/call. İki taşıma: Streamable HTTP ve stdio.
actor MCPConnection {
    let config: MCPServerConfig
    private var nextId = 1
    private var sessionId: String?
    private var protocolVersion = "2025-06-18"
    private var initialized = false
    /// HTTP isteklerine eklenecek başlıkları üretir (jeton yenileme dahil); hub verir.
    private let authHeader: @Sendable () async -> String?

    // stdio
    private var process: Process?
    private var stdin: FileHandle?
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var buffer = Data()

    init(config: MCPServerConfig, authHeader: @escaping @Sendable () async -> String?) {
        self.config = config
        self.authHeader = authHeader
    }

    func listTools() async throws -> [MCPTool] {
        try await ensureInitialized()
        var tools: [MCPTool] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let r = try await request("tools/list", params)
            for t in r["tools"] as? [[String: Any]] ?? [] {
                let ann = t["annotations"] as? [String: Any] ?? [:]
                tools.append(MCPTool(name: t["name"] as? String ?? "",
                                     description: t["description"] as? String ?? "",
                                     inputSchema: t["inputSchema"] as? [String: Any] ?? ["type": "object"],
                                     readOnly: ann["readOnlyHint"] as? Bool ?? false,
                                     destructive: ann["destructiveHint"] as? Bool ?? false))
            }
            cursor = r["nextCursor"] as? String
        } while cursor != nil && tools.count < 500
        return tools.filter { !$0.name.isEmpty }
    }

    func call(_ name: String, _ arguments: [String: Any]) async throws -> MCPToolResult {
        try await ensureInitialized()
        let r = try await request("tools/call", ["name": name, "arguments": arguments])
        var text: [String] = []
        var images: [(String, String)] = []
        for c in r["content"] as? [[String: Any]] ?? [] {
            switch c["type"] as? String {
            case "text": text.append(c["text"] as? String ?? "")
            case "image": images.append((c["mimeType"] as? String ?? "image/png", c["data"] as? String ?? ""))
            case "resource":
                let res = c["resource"] as? [String: Any] ?? [:]
                text.append(res["text"] as? String ?? "[kaynak: \(res["uri"] as? String ?? "")]")
            case "resource_link": text.append("[bağlantı: \(c["uri"] as? String ?? "")]")
            default: break
            }
        }
        if text.isEmpty, let structured = r["structuredContent"],
           let d = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
            text.append(String(data: d, encoding: .utf8) ?? "")
        }
        return MCPToolResult(text: text.joined(separator: "\n"), images: images, isError: r["isError"] as? Bool ?? false)
    }

    func close() {
        process?.terminate()
        process = nil
        initialized = false
        sessionId = nil
    }

    // MARK: - JSON-RPC

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        let r = try await request("initialize", [
            "protocolVersion": protocolVersion,
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "Serçe", "version": "0.3"],
        ])
        if let v = r["protocolVersion"] as? String { protocolVersion = v }
        initialized = true
        try await notify("notifications/initialized")
    }

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextId
        nextId += 1
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let response: [String: Any]
        switch config.transport {
        case .http(let url, let headers): response = try await httpSend(msg, url: url, headers: headers, expectId: id)
        case .stdio: response = try await stdioSend(msg, id: id)
        }
        if let err = response["error"] as? [String: Any] {
            throw MCPError.rpc(err["message"] as? String ?? "Sunucu hata döndü.")
        }
        return response["result"] as? [String: Any] ?? [:]
    }

    private func notify(_ method: String) async throws {
        let msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        switch config.transport {
        case .http(let url, let headers): _ = try? await httpSend(msg, url: url, headers: headers, expectId: nil)
        case .stdio: try writeLine(msg)
        }
    }

    // MARK: - Streamable HTTP

    private func httpSend(_ msg: [String: Any], url: URL, headers: [String: String], expectId: Int?) async throws -> [String: Any] {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 120
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let auth = await authHeader() { r.setValue(auth, forHTTPHeaderField: "Authorization") }
        if let sessionId { r.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        r.httpBody = try JSONSerialization.data(withJSONObject: msg)

        let (bytes, resp) = try await URLSession.shared.bytes(for: r)
        guard let http = resp as? HTTPURLResponse else { throw MCPError.transport("Yanıt yok.") }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionId = sid }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw MCPError.needsAuth(wwwAuthenticate: http.value(forHTTPHeaderField: "WWW-Authenticate"))
        }
        if http.statusCode == 404, sessionId != nil {
            // Oturum süresi dolmuş: baştan başla.
            sessionId = nil
            initialized = false
            throw MCPError.transport("Oturum yenilendi, tekrar dene.")
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 400 { break } }
            throw MCPError.http(http.statusCode, body)
        }
        guard let expectId else { return [:] }

        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.contains("text/event-stream") {
            // Akıştaki mesajlardan bizim kimliğimize ait yanıtı bekle.
            var data = ""
            for try await line in bytes.lines {
                if line.hasPrefix("data:") {
                    data += String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if let obj = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] {
                        data = ""
                        if (obj["id"] as? Int) == expectId { return obj }
                    }
                } else if line.isEmpty {
                    data = ""
                }
            }
            throw MCPError.transport("Akış yanıt vermeden kapandı.")
        }
        var body = Data()
        for try await b in bytes { body.append(b) }
        if let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] { return obj }
        if let arr = (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]],
           let match = arr.first(where: { ($0["id"] as? Int) == expectId }) { return match }
        throw MCPError.transport("Yanıt okunamadı.")
    }

    // MARK: - stdio

    private func startProcess() throws {
        guard process == nil, case .stdio(let command, let args, let env) = config.transport else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [command] + args
        var environment = ProcessInfo.processInfo.environment
        // Finder'dan açılan uygulamanın PATH'i kısadır; npx/uvx/docker bulunsun.
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin",
                     FileManager.default.homeDirectoryForCurrentUser.path + "/.cargo/bin"]
        environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            Task { await self?.received(d) }
        }
        p.terminationHandler = { [weak self] _ in Task { await self?.terminated() } }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
    }

    private func stdioSend(_ msg: [String: Any], id: Int) async throws -> [String: Any] {
        do { try startProcess() } catch {
            throw MCPError.transport("Komut başlatılamadı: \(error.localizedDescription)")
        }
        return try await withCheckedThrowingContinuation { c in
            pending[id] = c
            do { try writeLine(msg) } catch {
                pending.removeValue(forKey: id)
                c.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(90))
                self.timeout(id)
            }
        }
    }

    private func timeout(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: MCPError.transport("Sunucu 90 sn içinde yanıt vermedi."))
    }

    private func writeLine(_ msg: [String: Any]) throws {
        guard let stdin else { throw MCPError.transport("Süreç çalışmıyor.") }
        var d = try JSONSerialization.data(withJSONObject: msg)
        d.append(0x0A)
        try stdin.write(contentsOf: d)
    }

    private func received(_ d: Data) {
        guard !d.isEmpty else { return }
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let id = obj["id"] as? Int, obj["method"] == nil else { continue }
            pending.removeValue(forKey: id)?.resume(returning: obj)
        }
    }

    private func terminated() {
        process = nil
        stdin = nil
        initialized = false
        for (_, c) in pending { c.resume(throwing: MCPError.transport("Sunucu süreci kapandı.")) }
        pending = [:]
    }
}
