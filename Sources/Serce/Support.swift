import Foundation

/// Uygulamanın diskteki yeri: hook betiği ve yerel jeton ~/Library/Application Support/Serce altında durur.
enum Support {
    static let port: UInt16 = 47823
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Serce", isDirectory: true)
    static var hookURL: URL { dir.appendingPathComponent("serce-hook") }
    static var tokenURL: URL { dir.appendingPathComponent("token") }
    private(set) static var token = ""

    static func prepare() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if let t = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 32 {
            token = t
        } else {
            var bytes = [UInt8](repeating: 0, count: 24)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            token = bytes.map { String(format: "%02x", $0) }.joined()
            try? token.write(to: tokenURL, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        }

        try? hookScript.write(to: hookURL, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)
    }

    /// Ajanlar her olayda bu betiği çağırır: `serce-hook [--agent ad] Olay` ya da `serce-hook --statusline`.
    /// Serçe kapalıysa sessizce çıkar; ajanı asla bekletmez. Yalnızca izin ve soru olayları yanıt bekler;
    /// cevap gelmezse boş çıkar ve ajan terminalde sorar (Copilot için açıkça "ask").
    static var hookScript: String {
        """
        #!/bin/sh
        # Serçe — ajan hook köprüsü. Uygulama tarafından her açılışta yeniden yazılır.
        DIR="$(cd "$(dirname "$0")" && pwd)"
        TOKEN="$(cat "$DIR/token" 2>/dev/null)"
        BASE="http://127.0.0.1:\(port)/hook"
        AGENT=""
        if [ "$1" = "--agent" ]; then AGENT="$2"; shift 2; fi
        EVENT="$1"

        # Claude Code durum satırı: plan kullanımını aktar, sonra kullanıcının önceki durum satırını çalıştır.
        if [ "$EVENT" = "--statusline" ]; then
          PAYLOAD="$(cat)"
          printf '%s' "$PAYLOAD" | curl -s --connect-timeout 0.3 -m 1 -H "X-Serce-Token: $TOKEN" --data-binary @- "$BASE?event=StatusLine" >/dev/null 2>&1
          PREV="$(/usr/bin/plutil -extract command raw -o - "$DIR/statusline-previous.json" 2>/dev/null)"
          if [ -n "$PREV" ]; then printf '%s' "$PAYLOAD" | /bin/sh -c "$PREV"; fi
          exit 0
        fi

        # Hook'ların kendi terminali yok; ajan sürecine kadar üst süreçlerde ara.
        TTY=""; P=$$; N=0
        while [ -z "$TTY" ] && [ "$P" -gt 1 ] 2>/dev/null && [ $N -lt 8 ]; do
          T="$(ps -o tty= -p "$P" 2>/dev/null | tr -d ' ')"
          case "$T" in ""|"?"|"??") ;; *) TTY="/dev/$T" ;; esac
          P="$(ps -o ppid= -p "$P" 2>/dev/null | tr -d ' ')"; N=$((N+1))
        done
        URL="$BASE?event=$EVENT&agent=$AGENT&entry=${CLAUDE_CODE_ENTRYPOINT:-}&bid=${__CFBundleIdentifier:-}&term=${TERM_PROGRAM:-}&tty=$TTY"

        case "$EVENT" in
          PermissionRequest|permissionRequest|Ask)
            OUT="$(curl -s --connect-timeout 1 -m 125 -H "X-Serce-Token: $TOKEN" --data-binary @- "$URL" 2>/dev/null)"
            if [ -n "$OUT" ]; then printf '%s\\n' "$OUT"
            elif [ "$AGENT" = "copilot" ]; then printf '{"permissionDecision":"ask"}\\n'; fi
            ;;
          SessionStart)
            # Serçe proje hafızasını bağlam olarak döndürebilir (yalnızca Claude Code okur).
            OUT="$(curl -s --connect-timeout 0.3 -m 1.5 -H "X-Serce-Token: $TOKEN" --data-binary @- "$URL" 2>/dev/null)"
            if [ -n "$OUT" ] && [ -z "$AGENT" ]; then printf '%s\\n' "$OUT"; fi
            ;;
          *)
            curl -s --connect-timeout 0.3 -m 1 -H "X-Serce-Token: $TOKEN" --data-binary @- "$URL" >/dev/null 2>&1
            if [ "$AGENT" = "cursor" ] && [ "$EVENT" = "beforeSubmitPrompt" ]; then printf '{"continue":true}\\n'; fi
            ;;
        esac
        exit 0

        """
    }
}
