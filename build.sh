#!/bin/bash
# DockToggle build script
#
# Kullanim:
#   ./build.sh            -> sadece derler (build/DockToggle.app), test icin
#   ./build.sh --install  -> derler, /Applications'a kurar, build kopyasini siler
#
#   UNIVERSAL=1 ./build.sh   -> Apple Silicon + Intel tek paket (tam Xcode gerekebilir)
set -euo pipefail

APP_NAME="DockToggle"
BUNDLE_ID="com.local.docktoggle"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
BIN="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
INSTALL_PATH="/Applications/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

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

echo "==> Ad-hoc imzalaniyor"
codesign --force --sign - "$APP_BUNDLE"

if [ "${1:-}" = "--install" ]; then
  echo "==> /Applications'a kuruluyor"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  rm -rf "$INSTALL_PATH"
  cp -R "$APP_BUNDLE" "$INSTALL_PATH"
  "$LSREGISTER" -u "$APP_BUNDLE" 2>/dev/null || true
  rm -rf "$BUILD_DIR"
  # Ad-hoc imza her derlemede degistigi icin eski Erisilebilirlik izni yeni
  # surume gecmez (listede acik gorunse bile). Eski kaydi sifirla; uygulama
  # acilinca izin istemi yeniden gelir.
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  # Ikon onbellegini yenile: once paketin tarihini guncelle, sonra yeniden kaydet
  touch "$INSTALL_PATH"
  "$LSREGISTER" -f "$INSTALL_PATH"
  killall iconservicesagent 2>/dev/null || true
  open "$INSTALL_PATH"
  echo "==> Kuruldu ve baslatildi: $INSTALL_PATH"
  echo "    Acilan istemde DockToggle'a Erisilebilirlik izni ver."
else
  echo "==> Bitti: $APP_BUNDLE ($(lipo -archs "$BIN"))"
  echo "Test icin:   open \"$APP_BUNDLE\""
  echo "Kurmak icin: ./build.sh --install"
fi
