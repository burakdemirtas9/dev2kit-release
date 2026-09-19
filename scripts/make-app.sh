#!/bin/bash
# Release derlemesi yapıp Secora.app bundle'ı üretir.
#
# İmza: Developer ID sertifikası varsa onunla + Hardened Runtime ile imzalar
# (notarization'a hazır). Yoksa ad-hoc imzalar ve uyarır — ad-hoc imzalı
# uygulama başka bir Mac'te Gatekeeper tarafından engellenir.
#
# Kullanım: ./scripts/make-app.sh  → build/Secora.app
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.1.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/Secora.app"
ENTITLEMENTS="Sources/SecoraApp/Resources/Secora.entitlements"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/SecoraApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Secora"
cp Sources/SecoraApp/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Secora</string>
    <key>CFBundleIdentifier</key>
    <string>com.secora.app</string>
    <key>CFBundleName</key>
    <string>Secora</string>
    <key>CFBundleDisplayName</key>
    <string>Secora</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Developer ID sertifikası var mı?
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" \
    | head -1 \
    | sed -E 's/.*"(.+)".*/\1/' || true)"

if [ -n "$IDENTITY" ]; then
    echo "İmzalanıyor: $IDENTITY"
    # --options runtime: Hardened Runtime (notarization için zorunlu)
    # --timestamp: güvenli zaman damgası (sertifika süresi dolsa da imza geçerli kalır)
    codesign --force \
        --sign "$IDENTITY" \
        --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --timestamp \
        "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    echo
    echo "Hazır: $APP (Developer ID ile imzalı, Hardened Runtime açık)"
    echo "Sonraki adım: ./scripts/notarize.sh"
else
    # Ad-hoc imza: yalnızca bu makinede çalışır.
    codesign --force --sign - "$APP"
    echo
    echo "Hazır: $APP  →  open $APP"
    echo
    echo "UYARI: Developer ID sertifikası bulunamadı, ad-hoc imzalandı."
    echo "  Bu uygulama YALNIZCA bu makinede çalışır; başka bir Mac'te"
    echo "  Gatekeeper engeller. Dağıtım için Apple Developer Program"
    echo "  üyeliği ve 'Developer ID Application' sertifikası gerekir."
    echo "  Ayrıntı: docs/RELEASE.md"
fi
