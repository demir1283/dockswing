#!/bin/bash
# DockSwing surum paketi olusturur ve (istenirse) GitHub Release olarak yayinlar.
#
# Kullanim:
#   ./release.sh              -> build/DockSwing-<surum>.zip olusturur
#   ./release.sh --publish    -> ayrica GitHub Release olusturur ve zip'i yukler (gh gerekir)
#
# Notarize (istege bagli, Apple Developer hesabi gerekir):
#   export DEVELOPER_ID="Developer ID Application: Ad Soyad (TAKIMID)"
#   export NOTARY_PROFILE="dockswing"   # xcrun notarytool store-credentials ile kaydedilmis
# Bu degiskenler yoksa paket yerel sertifika / ad-hoc imzayla olusur; indiren kullanici
# ilk acilista Gatekeeper uyarisini README'deki adimla gecmelidir.
set -euo pipefail

APP_NAME="DockSwing"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Info.plist")"
TAG="v$VERSION"
ZIP="$BUILD_DIR/$APP_NAME-$VERSION.zip"

echo "==> Surum $VERSION"
UNIVERSAL=1 "$ROOT/build.sh"

if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "==> Developer ID ile imzalaniyor"
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP_BUNDLE"
  codesign --verify --strict "$APP_BUNDLE"
fi

echo "==> Paketleniyor"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP"

if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> Notarize ediliyor (birkac dakika surebilir)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP"
  NOTARIZED=1
else
  NOTARIZED=0
fi

echo "==> Hazir: $ZIP"

if [ "${1:-}" = "--publish" ]; then
  command -v gh >/dev/null || { echo "gh bulunamadi: brew install gh"; exit 1; }
  NOTES="DockSwing $VERSION"
  if [ "$NOTARIZED" = "0" ]; then
    NOTES="$NOTES

Bu paket notarize edilmemistir. Indirdikten sonra ilk acilistan once:
\`\`\`
xattr -dr com.apple.quarantine /Applications/DockSwing.app
\`\`\`"
  fi
  if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$ZIP" --clobber
  else
    gh release create "$TAG" "$ZIP" --title "DockSwing $TAG" --notes "$NOTES"
  fi
  echo "==> Yayinlandi: $TAG"
fi
