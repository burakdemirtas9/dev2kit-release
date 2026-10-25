#!/bin/bash
# Notarize edilmiş dev2kit.app'ten şirket içi dağıtım paketlerini üretir:
#
#   build/dev2kit-<sürüm>.pkg  Developer ID Installer ile imzalı, notarize
#                              edilmiş ve biletli. /Applications'a kurar.
#                              MDM (Jamf, Intune vb.) ile sorusuz dağıtım için;
#                              elle çift tıklanırsa yönetici parolası ister.
#   build/dev2kit-<sürüm>.zip  Biletli .app. Kullanıcı ~/Applications'a
#                              sürükleyerek parolasız kurar.
#
# Sıra: ./scripts/make-app.sh → ./scripts/notarize.sh → ./scripts/make-pkg.sh
# Ön koşul: "Developer ID Installer" sertifikası ve notarize.sh'teki kimlik
# profili (NOTARY_PROFILE, varsayılan "dev2kit").
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/dev2kit.app"
PROFILE="${NOTARY_PROFILE:-dev2kit}"

if [ ! -d "$APP" ]; then
    echo "Hata: $APP yok. Önce ./scripts/make-app.sh ve ./scripts/notarize.sh." >&2
    exit 1
fi
# pkg içindeki uygulama da biletli olmalı: çevrimdışı ilk açılışta da
# Gatekeeper onayı Apple'a sormadan bulsun.
if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "Hata: $APP notarize edilip biletlenmemiş. Önce ./scripts/notarize.sh." >&2
    exit 1
fi

INSTALLER_ID="$(security find-identity -v -p basic 2>/dev/null \
    | grep "Developer ID Installer" \
    | head -1 \
    | sed -E 's/.*"(.+)".*/\1/' || true)"
if [ -z "$INSTALLER_ID" ]; then
    echo "Hata: 'Developer ID Installer' sertifikası bulunamadı." >&2
    echo "  Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Installer" >&2
    exit 1
fi

PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
NAME="dev2kit-${VERSION}-${BUILD_NUMBER}"
PKG="build/${NAME}.pkg"
ZIP="build/${NAME}.zip"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "→ Bileşen paketi"
mkdir -p "$WORK/root"
ditto "$APP" "$WORK/root/dev2kit.app"
# Taşınabilirlik kapalı: taşınabilir pakette Installer aynı bundle kimliğini
# diskte başka bir yerde (ör. build/ klasörü) bulursa uygulamayı ORAYA
# kurar; paket hep /Applications'a kursun. macOS 27'de --analyze anahtarı
# hiç yazmıyor ve paket zaten taşınamaz çıkıyor (PackageInfo: <relocate/>,
# 2026-10-25 ölçüldü); eski sürümler için açıkça yazılır. `plutil -replace`
# anahtar yoksa ekler (PlistBuddy Set yok diye duruyordu).
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool false "$WORK/component.plist"
pkgbuild --root "$WORK/root" \
    --component-plist "$WORK/component.plist" \
    --install-location /Applications \
    --identifier "$BUNDLE_ID.pkg" \
    --version "$VERSION.$BUILD_NUMBER" \
    "$WORK/component.pkg"

echo "→ Dağıtım paketi (imzalı): $INSTALLER_ID"
rm -f "$PKG"
productbuild --package "$WORK/component.pkg" \
    --sign "$INSTALLER_ID" \
    --timestamp \
    "$PKG"
pkgutil --check-signature "$PKG"

echo "→ Apple'a gönderiliyor (birkaç dakika sürebilir)"
xcrun notarytool submit "$PKG" --keychain-profile "$PROFILE" --wait

echo "→ Bilet iliştiriliyor ve doğrulanıyor"
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"
spctl --assess --type install --verbose=2 "$PKG"

echo "→ zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Hazır:"
echo "  $PKG  (MDM ile dağıtım; elle kurulumda yönetici parolası ister)"
echo "  $ZIP  (parolasız kurulum: açıp ~/Applications'a sürükle)"
shasum -a 256 "$PKG" "$ZIP"
