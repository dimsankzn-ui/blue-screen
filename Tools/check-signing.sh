#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/signing-check
cp build/checks build/signing-check/first
cp build/virtual-screen-checks build/signing-check/update
zsh Tools/sign-macos.sh build/signing-check/first local.bluescreen.signing-check
zsh Tools/sign-macos.sh build/signing-check/update local.bluescreen.signing-check
codesign -d -r- build/signing-check/first > build/signing-check/first.requirement 2>&1
codesign -d -r- build/signing-check/update > build/signing-check/update.requirement 2>&1
first_requirement=$(sed -n 's/^designated => //p' build/signing-check/first.requirement)
update_requirement=$(sed -n 's/^designated => //p' build/signing-check/update.requirement)
[[ -n "$first_requirement" && "$first_requirement" == "$update_requirement" && "$first_requirement" == *'certificate leaf'* ]] || { print -u2 'FAIL: signing identity is unstable'; exit 1; }
codesign --verify --strict -R "=$first_requirement" build/signing-check/update
print 'PASS: different executables share a certificate-bound update identity'
