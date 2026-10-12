import AppKit
import SwiftUI

/// Demo ve anlık görüntü için örnek bir Claude Code oturumu: oku, düzenle, test et.
enum DemoScript {
    static func make() -> (steps: [(Double, HookEvent)], after: [(Double, HookEvent)]) {
        let sid = "demo-\(Int.random(in: 1000...9999))"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = home + "/Projeler/kesit"
        func ev(_ name: String, _ extra: [String: Any] = [:]) -> HookEvent {
            var p: [String: Any] = ["session_id": sid, "cwd": dir, "hook_event_name": name]
            p.merge(extra) { $1 }
            return HookEvent(name: name, payload: p, bundleId: "com.mitchellh.ghostty", term: "ghostty")
        }
        let file = dir + "/src/fatura.ts"
        let original = "import { Kalem } from './tipler'\n\nconst KDV = 0.18\n\nexport function toplam(kalemler: Kalem[]) {\n  const ara = kalemler.reduce((s, k) => s + k.fiyat, 0)\n  return ara * (1 + KDV)\n}\n"
        let editInput: [String: Any] = ["file_path": file, "old_string": "const KDV = 0.18", "new_string": "const KDV = 0.20 // 2026"]
        let bashInput: [String: Any] = ["command": "npm test", "description": "Testleri çalıştır"]
        let steps: [(Double, HookEvent)] = [
            (0.0, ev("SessionStart")),
            (0.5, ev("UserPromptSubmit", ["prompt": "KDV oranını %20 yap ve testleri çalıştır"])),
            (1.2, ev("PreToolUse", ["tool_name": "Read", "tool_input": ["file_path": file]])),
            (2.2, ev("PostToolUse", ["tool_name": "Read", "tool_input": ["file_path": file],
                                    "tool_response": ["type": "text", "file": ["filePath": file, "content": original, "startLine": 1]]])),
            (3.0, ev("PreToolUse", ["tool_name": "Edit", "tool_input": editInput])),
            (4.0, ev("PostToolUse", ["tool_name": "Edit", "tool_input": editInput, "tool_response": ["structuredPatch": [[
                "oldStart": 1, "oldLines": 8, "newStart": 1, "newLines": 8,
                "lines": [" import { Kalem } from './tipler'", " ", "-const KDV = 0.18", "+const KDV = 0.20 // 2026", " ",
                          " export function toplam(kalemler: Kalem[]) {", "   const ara = kalemler.reduce((s, k) => s + k.fiyat, 0)",
                          "   return ara * (1 + KDV)", " }"]]]]])),
            (5.0, ev("PreToolUse", ["tool_name": "Bash", "tool_input": bashInput])),
            (5.2, ev("PermissionRequest", ["tool_name": "Bash", "tool_input": bashInput,
                                          "permission_suggestions": [["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                                                      "rules": [["toolName": "Bash", "ruleContent": "npm test:*"]]]]])),
        ]
        let after: [(Double, HookEvent)] = [
            (1.5, ev("PostToolUse", ["tool_name": "Bash", "tool_input": bashInput, "tool_response": [
                "stdout": "> kesit@1.0.0 test\n> vitest run\n\n ✓ tests/fatura.test.ts (6)\n   ✓ KDV %20 uygulanır (3 ms)\n\n Test Files  1 passed (1)\n      Tests  48 passed (48)", "stderr": ""]])),
            (2.3, ev("Stop")),
        ]
        return (steps, after)
    }
}

/// Demo oturumunu adım adım oynatır ve her ana görünümü PNG olarak kaydeder (ekranla etkileşim yok).
@MainActor enum Snapshot {
    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppState.shared
        let store = app.store
        let model = NotchModel()
        model.expanded = true
        model.hooksInstalled = true
        model.notchWidth = 185
        model.notchHeight = 32
        let actions = NotchActions(decide: { _, _ in }, openTerminal: { _ in }, installHooks: {}, showMenu: {})
        let (steps, after) = DemoScript.make()

        func shot(_ name: String) {
            let view = ExpandedView(app: app, store: store, pills: app.pills, model: model, actions: actions)
                .frame(width: model.expandedWidth)
                .fixedSize(horizontal: false, vertical: true)
                .background(NotchShape(ear: model.ear, radius: 26).fill(.black))
                .environment(\.colorScheme, .dark)
                .environment(\.snapshotMode, true)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(name + ".png"))
            }
        }

        let responder = Responder { _ in }
        for (i, (_, e)) in steps.enumerated() {
            _ = store.handle(e, responder: e.name == "PermissionRequest" ? responder : nil)
            if i == 4 { shot("1-ana-calisiyor") }
        }
        shot("2-izin")
        if let a = store.approvals.first { store.decide(a, .allow) }
        for (_, e) in after { _ = store.handle(e) }
        model.selectedSession = nil
        shot("3-ana-bitti")
        model.selectedSession = store.sessions.first?.id
        shot("4-detay-terminal")
        model.pinnedStep = store.sessions.first?.steps.first { $0.tool == "Edit" }?.id
        shot("5-detay-diff")
        model.pinnedStep = store.sessions.first?.steps.first { $0.tool == "Read" }?.id
        shot("6-detay-okuma")
    }
}
