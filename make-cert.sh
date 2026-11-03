#!/bin/bash
# DockSwing icin sabit bir kod imzalama sertifikasi olusturur (bir kez calistirilir).
#
# Neden: Ad-hoc imza her derlemede degisir ve macOS Erisilebilirlik iznini o imzaya
# baglar; her yeniden derlemede izin kaybolur. Sabit bir sertifikayla imzalandiginda
# izin sertifika kimligine baglanir ve derlemeler arasinda korunur.
#
# Sertifika yalnizca bu Mac'te, ayri bir keychain'de tutulur:
#   ~/Library/Keychains/dockswing-signing.keychain-db
# Keychain parolasi rastgele uretilir ve .signing/keychain-pass dosyasina (0600)
# yazilir; bu klasor .gitignore'dadir. Kendi parolani kullanmak icin:
#   export DOCKSWING_KEYCHAIN_PASS="..."
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIGNING_DIR="$ROOT/.signing"
KEYCHAIN="$HOME/Library/Keychains/dockswing-signing.keychain-db"
CERT_NAME="DockSwing Self-Signed"
OPENSSL=/usr/bin/openssl   # macOS LibreSSL: uretilen .p12 'security import' ile uyumlu

mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"

# Keychain parolasi
PASS="${DOCKSWING_KEYCHAIN_PASS:-}"
if [ -z "$PASS" ]; then
  if [ -f "$SIGNING_DIR/keychain-pass" ]; then
    PASS="$(cat "$SIGNING_DIR/keychain-pass")"
  else
    PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
    (umask 077; printf '%s' "$PASS" > "$SIGNING_DIR/keychain-pass")
    echo "==> Keychain parolasi uretildi: .signing/keychain-pass"
  fi
fi

# Keychain
if [ ! -f "$KEYCHAIN" ]; then
  echo "==> Keychain olusturuluyor"
  security create-keychain -p "$PASS" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"   # otomatik kilitlenme yok
fi
security unlock-keychain -p "$PASS" "$KEYCHAIN"

# Keychain arama listesinde degilse, mevcutleri koruyarak ekle (codesign bulabilsin)
if ! security list-keychains -d user | grep -q "dockswing-signing"; then
  # shellcheck disable=SC2046
  security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
fi

if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "==> Sertifika zaten var: $CERT_NAME"
  exit 0
fi

echo "==> Sertifika olusturuluyor: $CERT_NAME"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = codesign
prompt             = no

[ dn ]
CN = $CERT_NAME

[ codesign ]
basicConstraints = critical, CA:false
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

P12_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$CERT_NAME" -out "$TMP/cert.p12" -passout "pass:$P12_PASS"

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign
# codesign anahtara her seferinde onay istemeden erissin
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KEYCHAIN" >/dev/null

# Sertifikaya yalnizca kod imzalama icin guven (kullanici duzeyinde). macOS bir kez
# parola soran bir onay penceresi gosterir. Reddedilirse imzalama yine calisir.
echo "==> Kod imzalama guveni ekleniyor (macOS parola sorabilir)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" \
  || echo "    Uyari: guven eklenemedi; imzalama yine de denenecek."

echo "==> Hazir. Artik ./build.sh --install bu sertifikayla imzalar."
echo "    Ilk kurulumda Erisilebilirlik iznini bir kez daha vermen gerekir; sonrakilerde korunur."
