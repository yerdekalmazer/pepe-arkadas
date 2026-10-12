import SwiftUI

/// AskUserQuestion'daki tek soru: 2–4 seçenek, tek ya da çoklu seçim.
struct QuestionItem: Equatable {
    struct Option: Equatable {
        var label: String
        var description: String
    }
    var question: String
    var header: String
    var options: [Option]
    var multiSelect: Bool

    /// tool_input'tan soruları okur; biçim bozuksa nil (kart açılmaz, ajan terminalde sorar).
    static func parse(_ input: [String: Any]) -> [QuestionItem]? {
        guard let raw = input["questions"] as? [[String: Any]], !raw.isEmpty, raw.count <= 4 else { return nil }
        var items: [QuestionItem] = []
        for q in raw {
            guard let text = q["question"] as? String, !text.isEmpty,
                  let opts = q["options"] as? [[String: Any]], (1...4).contains(opts.count) else { return nil }
            var options: [Option] = []
            for o in opts {
                guard let label = o["label"] as? String, !label.isEmpty else { return nil }
                options.append(Option(label: label, description: o["description"] as? String ?? ""))
            }
            items.append(QuestionItem(question: text, header: String((q["header"] as? String ?? "").prefix(12)),
                                      options: options, multiSelect: q["multiSelect"] as? Bool ?? false))
        }
        return items
    }
}

struct QuestionRequest: Identifiable {
    /// Cevabın hangi hook biçiminde döneceği.
    enum Format { case preToolUse, permissionRequest }

    let id = UUID()
    let sessionId: String
    let project: String
    let agent: String
    let key: String
    let items: [QuestionItem]
    /// Ajanın gönderdiği sorular aynen geri gönderilir (updatedInput.questions).
    let rawQuestions: [Any]
    let format: Format
    let responder: Responder

    /// Tek seçimde metin, çoklu seçimde dizi (Claude Code'un beklediği biçim).
    func answers(_ selections: [[String]]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (i, item) in items.enumerated() where i < selections.count && !selections[i].isEmpty {
            out[item.question] = item.multiSelect ? selections[i] : selections[i][0]
        }
        return out
    }

    func output(selections: [[String]]) -> String {
        let updated: [String: Any] = ["questions": rawQuestions, "answers": answers(selections)]
        let obj: [String: Any]
        switch format {
        case .preToolUse:
            obj = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": updated]]
        case .permissionRequest:
            obj = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                          "decision": ["behavior": "allow", "updatedInput": updated]]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Görünüm

struct QuestionView: View {
    let request: QuestionRequest
    let more: Int
    let answer: ([[String]]) -> Void
    let toTerminal: () -> Void

    @Environment(\.snapshotMode) private var snapshot
    @State private var selections: [[String]]
    @State private var index = 0
    @State private var other: [String]

    init(request: QuestionRequest, more: Int, initialSelections: [[String]]? = nil, initialIndex: Int = 0,
         answer: @escaping ([[String]]) -> Void, toTerminal: @escaping () -> Void) {
        self.request = request
        self.more = more
        self.answer = answer
        self.toTerminal = toTerminal
        _selections = State(initialValue: initialSelections ?? Array(repeating: [], count: request.items.count))
        _other = State(initialValue: Array(repeating: "", count: request.items.count))
        _index = State(initialValue: initialIndex)
    }

    private var item: QuestionItem { request.items[min(index, request.items.count - 1)] }
    private var complete: Bool { selections.allSatisfy { !$0.isEmpty } }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    Bird(mood: .alert, size: 64)
                    Badge(color: Palette.amber, symbol: "questionmark")
                }
                Text(request.project).font(.system(size: 14, weight: .bold)).lineLimit(1).padding(.top, 10)
                Text(AgentCatalog.name(request.agent)).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(request.items.count > 1 ? "\(request.items.count) soru soruyor" : "bir soru soruyor")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.amber)
                    .padding(.top, 14)
                if more > 0 {
                    Text("+\(more) istek daha bekliyor").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 140, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                if request.items.count > 1 { tabs }
                Text(item.question)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if item.multiSelect {
                    Text("Birden fazla seçebilirsin").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                VStack(spacing: 5) {
                    ForEach(Array(item.options.enumerated()), id: \.offset) { _, opt in
                        optionRow(opt)
                    }
                    otherRow
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button("Terminalde yanıtla", action: toTerminal).buttonStyle(Pill(kind: .ghost))
                    Spacer()
                    if index < request.items.count - 1 {
                        Button("Sonraki") { index += 1 }
                            .buttonStyle(Pill(kind: .quiet))
                            .disabled(selections[index].isEmpty)
                    }
                    Button("Gönder") { answer(selections) }
                        .buttonStyle(Pill(kind: .primary))
                        .disabled(!complete)
                        .opacity(complete ? 1 : 0.45)
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 300)
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(Array(request.items.enumerated()), id: \.offset) { i, q in
                Button {
                    index = i
                } label: {
                    HStack(spacing: 4) {
                        if !selections[i].isEmpty {
                            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.green)
                        }
                        Text(q.header.isEmpty ? "Soru \(i + 1)" : q.header).font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.white.opacity(i == index ? 0.16 : 0.05)))
                    .foregroundStyle(i == index ? .white : .white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func optionRow(_ opt: QuestionItem.Option) -> some View {
        let on = selections[index].contains(opt.label)
        return Button {
            toggle(opt.label)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: item.multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 12))
                    .foregroundStyle(on ? Palette.blue : .white.opacity(0.4))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(opt.label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    if !opt.description.isEmpty {
                        Text(opt.description).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(on ? 0.10 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? Palette.blue.opacity(0.7) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var otherRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            if snapshot {
                // ImageRenderer metin alanını çizemez.
                Text("Başka bir cevap yaz…").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.3))
                Spacer(minLength: 0)
            } else {
                TextField("Başka bir cevap yaz…", text: Binding(get: { other[index] }, set: { setOther($0) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.03)))
    }

    private func toggle(_ label: String) {
        other[index] = ""
        if item.multiSelect {
            if let i = selections[index].firstIndex(of: label) { selections[index].remove(at: i) }
            else { selections[index].append(label) }
        } else {
            selections[index] = [label]
            // Tek seçimde sıradaki cevaplanmamış soruya geç.
            if let next = selections.indices.first(where: { $0 > index && selections[$0].isEmpty }) { index = next }
        }
    }

    private func setOther(_ text: String) {
        other[index] = text
        let t = text.trimmingCharacters(in: .whitespaces)
        let labels = Set(item.options.map(\.label))
        var kept = item.multiSelect ? selections[index].filter { labels.contains($0) } : []
        if !t.isEmpty { kept.append(t) }
        selections[index] = kept
    }
}
