import Foundation
import Network

struct HookEvent {
    let name: String
    let payload: [String: Any]
    let bundleId: String
    let term: String
    var tty = ""
    /// Ajanın süreç kimliği (hook betiği üst süreçlerden bulur).
    var pid: Int32 = 0
    /// Olay Pepe'nin kendi başlattığı terminalsiz bir çalıştırmadan mı geliyor?
    var fromSerce = false
    /// Ajan kimliği ("claude", "codex", "gemini"…); AgentNormalizer belirler.
    var agent = AgentCatalog.claude
}

/// Yanıtın tek sefer gönderilmesini garanti eder (karar, zaman aşımı ve bağlantı kopması yarışabilir).
final class Responder: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let send: (String) -> Void

    init(_ send: @escaping (String) -> Void) { self.send = send }

    func respond(_ body: String) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        lock.unlock()
        send(body)
    }
}

/// Yalnızca 127.0.0.1'i dinleyen küçük HTTP sunucusu. serce-hook betiği olayları buraya POST eder.
final class HookServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "serce.hook")
    private let token: String
    private let onEvent: (HookEvent, Responder?, _ onClose: @escaping (@escaping () -> Void) -> Void) -> Void

    init(token: String, onEvent: @escaping (HookEvent, Responder?, @escaping (@escaping () -> Void) -> Void) -> Void) {
        self.token = token
        self.onEvent = onEvent
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Support.port)!)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { state in
            if case .failed(let err) = state { NSLog("Pepe: sunucu durdu: \(err)") }
        }
        l.start(queue: queue)
        listener = l
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, buffer: Data())
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = HTTPRequest.parse(buf) {
                self.handle(req, on: c)
            } else if complete || error != nil || buf.count > 8 << 20 {
                c.cancel()
            } else {
                self.read(c, buffer: buf)
            }
        }
    }

    private func handle(_ req: HTTPRequest, on c: NWConnection) {
        // Tanı: canlı oturumların kısa durumu (yalnızca bu Mac'ten, jetonla).
        if req.path == "/durum", req.headers["x-serce-token"] == token {
            let body: String = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    let list = AppState.shared.store.sessions.map { s -> [String: Any] in
                        ["id": String(s.id.prefix(8)), "proje": s.project, "durum": "\(s.status)", "ajan": s.agent,
                         "dokum": s.transcriptPath.isEmpty ? "YOK" : (FileManager.default.fileExists(atPath: s.transcriptPath) ? "var" : "dosya yok"),
                         "adim": s.steps.count, "kapali": s.ended]
                    }
                    let d = (try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted])) ?? Data()
                    return String(data: d, encoding: .utf8) ?? "[]"
                }
            }
            reply(c, status: "200 OK", body: body)
            return
        }
        guard req.path == "/hook", req.headers["x-serce-token"] == token else {
            reply(c, status: "403 Forbidden", body: "")
            return
        }
        let raw = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
        let (name, payload, agent) = AgentNormalizer.normalize(name: req.query["event"] ?? "", payload: raw,
                                                               agentArg: req.query["agent"] ?? "", entry: req.query["entry"] ?? "")
        var event = HookEvent(name: name, payload: payload,
                              bundleId: req.query["bid"] ?? "", term: req.query["term"] ?? "",
                              tty: req.query["tty"] ?? "", agent: agent)
        event.pid = Int32(req.query["pid"] ?? "") ?? 0
        event.fromSerce = req.query["serce"] == "1"

        if ProcessInfo.processInfo.environment["SERCE_DEBUG"] == "1" {
            NSLog("serce-debug event=\(name) bid=\(event.bundleId) term=\(event.term) tty=\(event.tty)")
        }
        guard name == "PermissionRequest" || name == "Ask" else {
            var body = ""
            // Claude Code oturumu açılırken proje hafızasının kısa özetini bağlam olarak ver.
            if name == "SessionStart", event.agent == AgentCatalog.claude, let cwd = payload["cwd"] as? String,
               let ctx = ProjectMemory.sessionContext(cwd: cwd),
               let d = try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": ["hookEventName": "SessionStart", "additionalContext": ctx]]) {
                body = String(data: d, encoding: .utf8) ?? ""
            }
            reply(c, status: "200 OK", body: body)
            onEvent(event, nil, { _ in })
            return
        }

        // İzin isteği: bağlantı açık kalır, kullanıcı karar verene kadar Claude Code bekler.
        let responder = Responder { [weak self] body in
            self?.queue.async { self?.reply(c, status: "200 OK", body: body) }
        }
        onEvent(event, responder) { [weak self] closed in
            // Hook süreci öldürülürse (ör. kullanıcı terminalden cevapladı) bağlantı kapanır.
            self?.queue.async {
                c.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
                    if complete || error != nil { closed() }
                }
            }
        }
    }

    private func reply(_ c: NWConnection, status: String, body: String) {
        let bytes = Data(body.utf8)
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(bytes)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

struct HTTPRequest {
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    /// İstek tamamlanmadıysa nil döner; okuyucu daha fazla veri bekler.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[sep.upperBound...]
        guard body.count >= length else { return nil }

        let comps = URLComponents(string: String(parts[1]))
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(path: comps?.path ?? "", query: query, headers: headers, body: Data(body.prefix(length)))
    }
}
