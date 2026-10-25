#!/bin/zsh
# Keep the same certificate across updates: ad-hoc cdhash identities break Keychain ACLs.
set -eu
cd "$(dirname "$0")/.."
artifact="$1"
identifier="$2"
if [[ -n "${BLUESCREEN_SIGNING_IDENTITY:-}" ]]; then
    codesign --force --sign "$BLUESCREEN_SIGNING_IDENTITY" --identifier "$identifier" "$artifact"
    exit
fi
signing_dir="$PWD/.local-signing"
keychain="$signing_dir/development.keychain-db"
umask 077
mkdir -p "$signing_dir"
if [[ ! -f "$signing_dir/identity.pem" ]]; then
    [[ ! -f "$keychain" ]] || { print -u2 'Signing certificate missing; restore .local-signing from your private backup.'; exit 1; }
    openssl rand -hex 32 > "$signing_dir/password"
    cat > "$signing_dir/openssl.cnf" <<'CONFIG'
[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=Blue Screen Local Development
[extensions]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CONFIG
    openssl req -new -newkey rsa:3072 -nodes -x509 -days 3650 -config "$signing_dir/openssl.cnf" -keyout "$signing_dir/identity.key" -out "$signing_dir/identity.pem" 2> "$signing_dir/generation.log"
fi
if [[ ! -f "$keychain" ]]; then
    # Apple Security imports the legacy PKCS12 algorithms, including with OpenSSL 3.
    openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -inkey "$signing_dir/identity.key" -in "$signing_dir/identity.pem" -name 'Blue Screen Local Development' -out "$signing_dir/identity.p12" -passout "file:$signing_dir/password"
    security create-keychain -p "$(cat "$signing_dir/password")" "$keychain"
    security unlock-keychain -p "$(cat "$signing_dir/password")" "$keychain"
    security import "$signing_dir/identity.p12" -k "$keychain" -P "$(cat "$signing_dir/password")" -T /usr/bin/codesign > "$signing_dir/import.log"
    security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat "$signing_dir/password")" "$keychain" > "$signing_dir/partition.log"
fi
security unlock-keychain -p "$(cat "$signing_dir/password")" "$keychain"
codesign --force --sign 'Blue Screen Local Development' --keychain "$keychain" --timestamp=none --identifier "$identifier" "$artifact"
