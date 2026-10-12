import SwiftUI

/// Ajanlar özellik grubunun anlık görüntü kareleri (Snapshot.run çağırır).
@MainActor enum AgentSnapshots {
    static func run(store: SessionStore, model: NotchModel, actions: NotchActions,
                    shot: (String) -> Void, shotView: (String, AnyView) -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func send(_ name: String, _ payload: [String: Any], agent: String, responder: Responder? = nil) {
            let (n, p, a) = AgentNormalizer.normalize(name: name, payload: payload, agentArg: agent, entry: "")
            _ = store.handle(HookEvent(name: n, payload: p, bundleId: "", term: "", agent: a), responder: responder)
        }

        // Farklı ajanlar
        send("SessionStart", ["session_id": "cx", "cwd": home + "/Projeler/deste"], agent: "codex")
        send("UserPromptSubmit", ["session_id": "cx", "cwd": home + "/Projeler/deste", "prompt": "Kart destesini karıştır"], agent: "codex")
        send("PreToolUse", ["session_id": "cx", "tool_name": "Bash", "tool_input": ["command": "cargo test"]], agent: "codex")
        send("BeforeAgent", ["session_id": "gm", "cwd": home + "/Projeler/fihrist", "prompt": "Arama sonuçlarını sırala"], agent: "gemini")
        send("BeforeTool", ["session_id": "gm", "tool_name": "read_file", "tool_input": ["absolute_path": home + "/Projeler/fihrist/arama.swift"]], agent: "gemini")
        send("beforeSubmitPrompt", ["conversation_id": "cu", "workspace_roots": [home + "/Projeler/kilodex"], "prompt": "Skor tablosunu düzelt"], agent: "cursor")
        send("afterShellExecution", ["conversation_id": "cu", "command": "npm run lint", "output": "✓ 0 sorun"], agent: "cursor")
        model.selectedSession = nil
        shot("7-ajanlar")

        // Soru kartı: tek seçim
        let single: [String: Any] = ["questions": [[
            "question": "Kullanıcı verisini nerede saklayalım?", "header": "Depolama", "multiSelect": false,
            "options": [["label": "Supabase", "description": "Hazır kimlik doğrulama, Postgres"],
                        ["label": "SQLite", "description": "Yerel dosya, sunucu yok"],
                        ["label": "iCloud", "description": "Apple hesabıyla senkron"]]]]]
        send("Ask", ["session_id": "q1", "cwd": home + "/Projeler/cekmece", "tool_name": "AskUserQuestion", "tool_input": single],
             agent: "claude", responder: Responder { _ in })
        shot("8-soru-tek")
        if let q = store.questions.first {
            shotView("8b-soru-tek-secili", AnyView(QuestionView(request: q, more: 0, initialSelections: [["SQLite"]],
                                                                answer: { _ in }, toTerminal: {})))
            store.questionToTerminal(q)
        }

        // Soru kartı: çoklu seçim, iki soru
        let multi: [String: Any] = ["questions": [
            ["question": "Hangi platformlar?", "header": "Platform", "multiSelect": true,
             "options": [["label": "iOS"], ["label": "macOS"], ["label": "Web"]]],
            ["question": "Tema?", "header": "Tema", "multiSelect": false,
             "options": [["label": "Açık"], ["label": "Koyu"]]],
        ]]
        send("Ask", ["session_id": "q2", "cwd": home + "/Projeler/tessera-ios", "tool_name": "AskUserQuestion", "tool_input": multi],
             agent: "claude", responder: Responder { _ in })
        if let q = store.questions.first {
            shotView("9-soru-coklu", AnyView(QuestionView(request: q, more: 0, initialSelections: [["iOS", "macOS"], []],
                                                           answer: { _ in }, toTerminal: {})))
            store.questionToTerminal(q)
        }

        // Plan kullanımı
        let now = Date()
        let plan = PlanStore.shared
        plan.showClaude = true
        plan.showCodex = true
        plan.setForPreview(
            claude: PlanUsage(fiveHour: PlanWindow(usedPct: 42, resetsAt: now.addingTimeInterval(2 * 3600 + 840)),
                              sevenDay: PlanWindow(usedPct: 67, resetsAt: now.addingTimeInterval(3 * 86400 + 5 * 3600))),
            codex: PlanUsage(fiveHour: PlanWindow(usedPct: 12, resetsAt: now.addingTimeInterval(4 * 3600)),
                             sevenDay: PlanWindow(usedPct: 88, resetsAt: now.addingTimeInterval(86400)), planType: "plus", resetCredits: 2))
        shot("10-plan-pill")
        plan.showDetail = true
        shot("11-plan-detay")
        plan.showDetail = false

        // Haftalık özet
        var days: [String: RecapDay] = [:]
        let samples: [(Int, Int, Int, Int)] = [(3, 120, 14, 1), (1, 40, 5, 0), (0, 0, 0, 0), (4, 210, 22, 3), (2, 95, 9, 1), (5, 260, 30, 2), (2, 70, 8, 0)]
        for (i, (sess, steps, allow, deny)) in samples.enumerated() {
            let date = Calendar.current.date(byAdding: .day, value: i - 6, to: now)!
            var d = RecapDay(sessions: sess, steps: steps, allowed: allow, denied: deny)
            d.projects = ["kesit": steps / 2, "deste": steps / 3, "fihrist": steps / 6]
            d.agents = ["claude": max(0, sess - 1), "codex": sess > 0 ? 1 : 0]
            d.answered = sess > 2 ? 1 : 0
            days[RecapStore.key(date)] = d
        }
        RecapStore.shared.setForPreview(days)
        shotView("12-haftalik", AnyView(WeeklyRecapView(store: .shared)))
    }
}
