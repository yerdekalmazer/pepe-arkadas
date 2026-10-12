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

codesign --force --deep -s - "$APP"
echo "Hazır: $APP"
if [ "$1" = "--install" ]; then
  pkill -x Serce 2>/dev/null || true
  rm -rf "/Applications/Serçe.app"
  ditto "$APP" "/Applications/Serçe.app"
  open "/Applications/Serçe.app"
  echo "Kuruldu: /Applications/Serçe.app"
fi
