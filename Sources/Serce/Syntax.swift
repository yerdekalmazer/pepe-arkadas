import SwiftUI

/// Dil bağımsız, hafif sözdizimi renklendirme: anahtar kelime, metin, sayı, yorum, fonksiyon, tip.
enum Syntax {
    static let keywords: Set<String> = [
        "import", "from", "export", "default", "function", "const", "let", "var", "return", "if", "else",
        "for", "while", "do", "switch", "case", "break", "continue", "class", "struct", "enum", "func",
        "def", "async", "await", "new", "true", "false", "nil", "null", "undefined", "self", "this",
        "static", "private", "public", "protocol", "extension", "guard", "in", "of", "try", "catch",
        "throw", "throws", "interface", "type", "extends", "implements", "lambda", "pass", "None", "True",
        "False", "and", "or", "not", "elif", "with", "as", "fn", "pub", "mut", "use", "impl", "package",
    ]
    static let keyword = Color(red: 0.78, green: 0.53, blue: 0.95)
    static let string = Color(red: 0.80, green: 0.87, blue: 0.55)
    static let number = Color(red: 0.98, green: 0.62, blue: 0.40)
    static let comment = Color.white.opacity(0.35)
    static let function = Color(red: 0.45, green: 0.72, blue: 1.0)
    static let typeName = Color(red: 0.98, green: 0.82, blue: 0.45)
    static let plain = Color.white.opacity(0.88)

    static func highlight(_ line: String) -> AttributedString {
        var out = AttributedString()
        let chars = Array(line)
        var i = 0

        func emit(_ s: String, _ c: Color) {
            var a = AttributedString(s)
            a.foregroundColor = c
            out += a
        }

        while i < chars.count {
            let c = chars[i]
            // Yorum: satırın geri kalanı
            if (c == "/" && i + 1 < chars.count && chars[i + 1] == "/") ||
               (c == "#" && (i == 0 || chars[i - 1] == " ")) {
                emit(String(chars[i...]), comment)
                break
            }
            if c == "\"" || c == "'" || c == "`" {
                var j = i + 1
                while j < chars.count, chars[j] != c { j += chars[j] == "\\" ? 2 : 1 }
                j = min(j + 1, chars.count)
                emit(String(chars[i..<j]), string)
                i = j
                continue
            }
            if c.isNumber {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "_" { j += 1 }
                emit(String(chars[i..<j]), number)
                i = j
                continue
            }
            if c.isLetter || c == "_" || c == "$" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "$" { j += 1 }
                let word = String(chars[i..<j])
                let color: Color
                if keywords.contains(word) { color = keyword }
                else if j < chars.count, chars[j] == "(" { color = function }
                else if word.first?.isUppercase == true { color = typeName }
                else { color = plain }
                emit(word, color)
                i = j
                continue
            }
            emit(String(c), plain.opacity(0.8))
            i += 1
        }
        return out
    }
}

/// Terminal çıktısında başarı/hata satırlarını boyar.
enum Terminal {
    static func colored(_ line: String) -> AttributedString {
        var a = AttributedString(line)
        let l = line.lowercased()
        if l.contains("fail") || l.contains("error") || line.contains("✗") || line.contains("✕") {
            a.foregroundColor = Palette.red
        } else if line.contains("PASS") || line.contains("✓") || line.contains("✔") || l.contains("passed") || l.hasSuffix(" ok") || l == "ok" {
            a.foregroundColor = Palette.green
        } else {
            a.foregroundColor = Color.white.opacity(0.72)
        }
        return a
    }
}
