#!/bin/bash
# Release derlemesi yapıp dev2kit.app bundle'ı üretir.
#
# İmza: Developer ID sertifikası varsa onunla + Hardened Runtime ile imzalar
# (notarization'a hazır). Yoksa ad-hoc imzalar ve uyarır — ad-hoc imzalı
# uygulama başka bir Mac'te Gatekeeper tarafından engellenir.
#
# Kullanım: ./scripts/make-app.sh  → build/dev2kit.app
set -euo pipefail
cd "$(dirname "$0")/.."

# Sürüm tek yerde: Dev2KitIdentity.version (User-Agent da oradan).
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/Dev2KitCore/Networking/Dev2KitIdentity.swift)"
VERSION="${VERSION:-0.0.0}"
# Derleme numarası da tek yerde: Dev2KitIdentity.build (release deposunda
# commit sayısı anlamsız). Yoksa eski yol: commit sayısı.
BUILD_NUMBER="$(sed -n 's/.*static let build = "\(.*\)".*/\1/p' Sources/Dev2KitCore/Networking/Dev2KitIdentity.swift)"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="build/dev2kit.app"
ENTITLEMENTS="Sources/Dev2KitApp/Resources/Dev2Kit.entitlements"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Dev2KitApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/dev2kit"
cp Sources/Dev2KitApp/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Status alanındaki kedi görselleri (HTTPCatImages Bundle.main'den okur).
cp -R Sources/Dev2KitApp/Resources/HTTPCats "$APP/Contents/Resources/HTTPCats"
# Araç çubuğundaki logo (HeaderLogoImage Bundle.main'den okur).
cp -R Sources/Dev2KitApp/Resources/Header "$APP/Contents/Resources/Header"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>dev2kit</string>
    <key>CFBundleIdentifier</key>
    <string>com.dev2kit.app</string>
    <key>CFBundleName</key>
    <string>dev2kit</string>
    <key>CFBundleDisplayName</key>
    <string>dev2kit</string>
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
