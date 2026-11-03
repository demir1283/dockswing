#!/bin/bash
# DockSwing build script
#
# Kullanim:
#   ./build.sh            -> sadece derler (build/DockSwing.app), test icin
#   ./build.sh --install  -> derler, /Applications'a kurar, build kopyasini siler
#
#   UNIVERSAL=1 ./build.sh   -> Apple Silicon + Intel tek paket (tam Xcode gerekebilir)
#
# Imza: ./make-cert.sh ile sabit sertifika olusturulduysa onunla imzalanir ve
# Erisilebilirlik izni derlemeler arasinda korunur. Yoksa ad-hoc imzalanir ve
# --install her kurulumda eski izin kaydini sifirlar (izin yeniden istenir).
set -euo pipefail

APP_NAME="DockSwing"
BUNDLE_ID="com.demir1283.dockswing"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
BIN="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
INSTALL_PATH="/Applications/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
KEYCHAIN="$HOME/Library/Keychains/dockswing-signing.keychain-db"
CERT_NAME="DockSwing Self-Signed"

echo "==> Temizleniyor"
if [ -d "$APP_BUNDLE" ]; then
  "$LSREGISTER" -u "$APP_BUNDLE" 2>/dev/null || true
fi
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
# Spotlight / Launchpad bu klasoru indekslemesin (cift kayit olmasin)
touch "$BUILD_DIR/.metadata_never_index"

echo "==> Derleniyor (swiftc)"
compile() {  # $1 = mimari, $2 = cikti
  swiftc -O -whole-module-optimization -target "$1-apple-macos13.0" \
    -framework Cocoa -framework ApplicationServices \
    "$ROOT"/Sources/*.swift -o "$2"
}
if [ "${UNIVERSAL:-0}" = "1" ]; then
  compile arm64  "$BUILD_DIR/$APP_NAME-arm64"
  compile x86_64 "$BUILD_DIR/$APP_NAME-x86_64"
  lipo -create "$BUILD_DIR/$APP_NAME-arm64" "$BUILD_DIR/$APP_NAME-x86_64" -output "$BIN"
  rm "$BUILD_DIR/$APP_NAME-arm64" "$BUILD_DIR/$APP_NAME-x86_64"
else
  compile "$(uname -m)" "$BIN"
fi

echo "==> Info.plist kopyalaniyor"
cp "$ROOT/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "==> Ikon olusturuluyor"
ICONSET="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z $SIZE $SIZE "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z $DOUBLE $DOUBLE "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# --- Imza -------------------------------------------------------------------
IDENTITY=""
if [ -f "$KEYCHAIN" ]; then
  PASS="${DOCKSWING_KEYCHAIN_PASS:-}"
  if [ -z "$PASS" ] && [ -f "$ROOT/.signing/keychain-pass" ]; then
    PASS="$(cat "$ROOT/.signing/keychain-pass")"
  fi
  if [ -n "$PASS" ]; then
    security unlock-keychain -p "$PASS" "$KEYCHAIN" >/dev/null 2>&1 || true
  fi
  # Sertifikanin SHA-1 ozeti: ad cakismalarindan bagimsiz, kesin kimlik
  IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
    | awk -v n="\"$CERT_NAME\"" 'index($0, n) { print $2; exit }')"
fi

if [ -n "$IDENTITY" ]; then
  echo "==> Sabit sertifikayla imzalaniyor ($CERT_NAME)"
  codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" "$APP_BUNDLE"
  SIGNED_WITH="cert"
else
  echo "==> Ad-hoc imzalaniyor (kalici izin icin bir kez: ./make-cert.sh)"
  codesign --force --sign - "$APP_BUNDLE"
  SIGNED_WITH="adhoc"
fi
codesign --verify --strict "$APP_BUNDLE" || { echo "IMZA DOGRULAMASI BASARISIZ"; exit 1; }

if [ "${1:-}" = "--install" ]; then
  echo "==> /Applications'a kuruluyor"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  rm -rf "$INSTALL_PATH"
  cp -R "$APP_BUNDLE" "$INSTALL_PATH"
  "$LSREGISTER" -u "$APP_BUNDLE" 2>/dev/null || true
  rm -rf "$BUILD_DIR"

  # Erisilebilirlik izni imzaya baglidir. Ad-hoc imzada her derleme yeni bir imza
  # demektir: eski kayit gecersiz kalir (listede acik gorunse bile), sifirlanir.
  # Sabit sertifikada izin korunur; yalnizca ad-hoc'tan sertifikaya ilk geciste
  # bir kez sifirlanir.
  MARKER="$ROOT/.signing/tcc-cert"
  if [ "$SIGNED_WITH" = "adhoc" ]; then
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
    rm -f "$MARKER"
  elif [ ! -f "$MARKER" ]; then
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
    mkdir -p "$ROOT/.signing" && touch "$MARKER"
    echo "    Sertifikaya ilk gecis: Erisilebilirlik iznini bir kez daha ver."
  fi

  # Ikon onbellegini yenile: once paketin tarihini guncelle, sonra yeniden kaydet
  touch "$INSTALL_PATH"
  "$LSREGISTER" -f "$INSTALL_PATH"
  killall iconservicesagent 2>/dev/null || true
  open "$INSTALL_PATH"
  echo "==> Kuruldu ve baslatildi: $INSTALL_PATH"
  if [ "$SIGNED_WITH" = "adhoc" ]; then
    echo "    Acilan istemde DockSwing'e Erisilebilirlik izni ver."
  fi
else
  echo "==> Bitti: $APP_BUNDLE ($(lipo -archs "$BIN"), imza: $SIGNED_WITH)"
  echo "Test icin:   open \"$APP_BUNDLE\""
  echo "Kurmak icin: ./build.sh --install"
fi
