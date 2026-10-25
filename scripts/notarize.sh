#!/bin/bash
# dev2kit.app'i Apple'a notarize ettirip bileti uygulamaya iliştirir.
#
# Ön koşullar:
#   1. Apple Developer Program üyeliği
#   2. ./scripts/make-app.sh Developer ID ile imzalamış olmalı
#   3. notarytool kimlik profili kurulu olmalı (bir kez):
#        xcrun notarytool store-credentials "dev2kit" \
#          --apple-id "eposta@ornek.com" \
#          --team-id "TAKIMKIMLIGI" \
#          --password "uygulama-ozel-parola"
#      (uygulama özel parola: appleid.apple.com → Oturum Açma ve Güvenlik)
#
# Kullanım: ./scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/dev2kit.app"
ZIP="build/dev2kit.zip"
PROFILE="${NOTARY_PROFILE:-dev2kit}"

if [ ! -d "$APP" ]; then
    echo "Hata: $APP yok. Önce ./scripts/make-app.sh çalıştır." >&2
    exit 1
fi

# Ad-hoc imzalı bundle notarize edilemez; önden yakala.
if ! codesign -dv --verbose=2 "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
    echo "Hata: $APP Developer ID ile imzalanmamış." >&2
    echo "  Sertifika kurulu mu? security find-identity -v -p codesigning" >&2
    exit 1
fi

echo "→ Arşivleniyor"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "→ Apple'a gönderiliyor (birkaç dakika sürebilir)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "→ Bilet iliştiriliyor"
xcrun stapler staple "$APP"

echo "→ Doğrulanıyor"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo
echo "Hazır: $APP notarize edildi ve biletlendi."
echo "Dağıtım paketleri (pkg + zip) için: ./scripts/make-pkg.sh"
