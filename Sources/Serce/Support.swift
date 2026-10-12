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

    /// Claude Code her olayda bu betiği çağırır. Serçe kapalıysa sessizce çıkar; ajanı asla bekletmez.
    /// Yalnızca PermissionRequest yanıt bekler; cevap gelmezse boş çıkar ve Claude Code terminalde sorar.
    static var hookScript: String {
        """
        #!/bin/sh
        # Serçe — Claude Code hook köprüsü. Uygulama tarafından her açılışta yeniden yazılır.
        EVENT="$1"
        DIR="$(cd "$(dirname "$0")" && pwd)"
        TOKEN="$(cat "$DIR/token" 2>/dev/null)"
        # Hook'ların kendi terminali yok; Claude Code sürecine kadar üst süreçlerde ara.
        TTY=""; P=$$; N=0
        while [ -z "$TTY" ] && [ "$P" -gt 1 ] 2>/dev/null && [ $N -lt 8 ]; do
          T="$(ps -o tty= -p "$P" 2>/dev/null | tr -d ' ')"
          case "$T" in ""|"?"|"??") ;; *) TTY="/dev/$T" ;; esac
          P="$(ps -o ppid= -p "$P" 2>/dev/null | tr -d ' ')"; N=$((N+1))
        done
        URL="http://127.0.0.1:\(port)/hook?event=$EVENT&bid=${__CFBundleIdentifier:-}&term=${TERM_PROGRAM:-}&tty=$TTY"
        if [ "$EVENT" = "PermissionRequest" ]; then
          curl -s --connect-timeout 1 -m 115 -H "X-Serce-Token: $TOKEN" --data-binary @- "$URL" 2>/dev/null
        else
          curl -s --connect-timeout 0.3 -m 1 -H "X-Serce-Token: $TOKEN" --data-binary @- "$URL" >/dev/null 2>&1
        fi
        exit 0

        """
    }
}
