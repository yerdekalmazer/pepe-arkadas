#!/bin/sh
# Serçe.app paketini üretir. Kullanım: ./build.sh [--install]
set -e
cd "$(dirname "$0")"
swift build -c release
BIN=.build/release/Serce
APP=build/Serçe.app
rm -rf "$APP" build/icon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/icon.iconset
cp "$BIN" "$APP/Contents/MacOS/Serce"

"$BIN" --render-icon build/icon-1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon-1024.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Serçe</string>
  <key>CFBundleDisplayName</key><string>Serçe</string>
  <key>CFBundleIdentifier</key><string>com.tahayerdekalmazer.serce</string>
  <key>CFBundleExecutable</key><string>Serce</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Serçe müzik çalarları kontrol etmek, Mail'de e-posta açmak ve doğru terminal sekmesine gitmek için diğer uygulamalarla konuşur.</string>
  <key>NSMicrophoneUsageDescription</key><string>Serçe sesli komutları ve dikteyi dinlemek için mikrofonu kullanır.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Konuşmanı yazıya çevirmek için; tanıma mümkünse bu Mac'te yapılır.</string>
  <key>NSContactsUsageDescription</key><string>"Enzo'ya e-posta at" dediğinde adresi rehberinde bulmak için.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Serçe'yi bir pencerenin üstüne bıraktığında o pencerenin görüntüsünü sohbete eklemek için.</string>
</dict></plist>
PLIST

# Kalıcı imza: Apple Development kimliği varsa onunla imzala. Böylece macOS her derlemeyi aynı uygulama sayar;
# Anahtar Zinciri ve gizlilik izinleri güncellemelerde sıfırlanmaz. Yoksa geçici (ad-hoc) imza.
IDENTITY="${SERCE_IMZA:-$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | awk '{print $2}')}"
if [ -n "$IDENTITY" ]; then
  codesign --force --deep -s "$IDENTITY" "$APP"
else
  codesign --force --deep -s - "$APP"
fi
echo "Hazır: $APP"
if [ "$1" = "--install" ]; then
  # Çalışan Serçe'yi dinlediği porttan bul (pgrep/pkill süreci göremiyor; eski sürüm açık kalıyordu).
  port_pid() { lsof -t -nP -iTCP:47823 -sTCP:LISTEN 2>/dev/null | head -1 || true; }
  OLD="$(port_pid)"
  if [ -n "$OLD" ]; then
    kill "$OLD" 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do [ -z "$(port_pid)" ] && break; sleep 0.3; done
    [ -n "$(port_pid)" ] && kill -9 "$OLD" 2>/dev/null || true
  fi
  rm -rf "/Applications/Serçe.app"
  ditto "$APP" "/Applications/Serçe.app"
  sleep 1
  open "/Applications/Serçe.app" 2>/dev/null || { sleep 2; open "/Applications/Serçe.app"; }
  # Yeni sürüm gerçekten açıldı mı? Portu yeni bir süreç dinlemeli.
  NEW=""
  for i in $(seq 1 20); do
    NEW="$(port_pid)"
    [ -n "$NEW" ] && [ "$NEW" != "$OLD" ] && break
    sleep 0.5
  done
  if [ -n "$NEW" ] && [ "$NEW" != "$OLD" ]; then echo "Kuruldu ve yeniden başlatıldı: /Applications/Serçe.app (pid $NEW)"; else echo "UYARI: yeni sürüm başlatılamadı"; exit 1; fi
fi
