# Serçe — mimari notları

Serçe, Claude Code (ve diğer ajan) oturumlarını MacBook notch'unda gösteren SwiftUI uygulaması.
Coucou'nun (github.com/Louis-CFM/coucou, MIT) macOS özelliklerini kendi kodu ve kendi karakteriyle (serçe) yeniden yapar.
Coucou adı, Mochi ve sesleri kullanılmaz.

## Derleme ve doğrulama
- `swift build` — hızlı derleme. `./build.sh` → `build/Serçe.app`; `./build.sh --install` → /Applications.
- Görsel doğrulama: `build/Serçe.app/Contents/MacOS/Serce --snapshot <klasör>` ekrana dokunmadan PNG üretir (Demo.swift → Snapshot).
  Yeni görünüm eklerken Snapshot.run'a kendi karelerini ekle. ImageRenderer ScrollView içini çizmez; `@Environment(\.snapshotMode)` ile düz bas.
- **Sentetik fare/klavye olayı gönderme.** Kullanıcı Mac'i aynı anda kullanıyor.
- Çalışan uygulamayı (`/Applications/Serçe.app`) öldürme/yeniden başlatma; dal birleştirildikten sonra ana oturum kurar.

## Parçalar
- `HookServer` 127.0.0.1:47823, `X-Serce-Token`. Hook betiği `~/Library/Application Support/Serce/serce-hook` (Support.swift üretir).
- `SessionStore` oturumlar, adımlar, izin kartları. `StepBuilder` hook verisini adıma çevirir.
- `AppState.shared` merkez: `store`, `pills` (PillRegistry), `tab` (home/chat/drop), `selectedPill`, `actions` (AppActions),
  `musicPlaying`, `attachments` (sohbete gidecek ekler).
- Pill'ler: `PillProvider` protokolü (Pills.swift). Kart `card()`, ayar `settings()`. Kayıt: `Features.register` içinde `app.pills.register(...)`.
- Ayarlar penceresi: `SettingsRegistry.shared.add(SettingsSection(...))`; ortak parçalar `SettingsGroup`, `SecretField`.
- Diğer ajanların kurulum satırları: `AgentRegistry.shared.add(AgentEntry(...))`.
- API anahtarları yalnızca `Keychain` (Keychain.swift). UserDefaults'a anahtar yazma.
- Kuş: `Bird(mood:size:tint:)`; ruh halleri `Mood` (sleep, idle, working, alert, happy, dance).

## Kurallar
- Arayüz metinleri Türkçe. Renkler `Palette`, panel arka planı `Palette.panel`, kod/terminal `Palette.editor`. Gradyan yok.
- Yeni özellik = yeni dosya(lar). Ortak dosyalara dokunman gerekiyorsa küçük ve açıklamalı tut; kayıt satırını Features.swift'e ekle.
- Ağ istekleri yalnızca kullanıcının anahtarını girdiği servislere. Hata durumunda pill sessizce "bağlanamadı" gösterir, uygulama çökmez.
- Swift 5 dil modu, macOS 14+. Ana iş parçacığı dışından `@MainActor` çağırma; `Task { @MainActor in }` kullan.
