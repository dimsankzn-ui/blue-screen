#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
source_app="$PWD/build/BlueScreen.app"
target_app="/Applications/Голубой экран.app"
[[ -d "$source_app" ]] || { print -u2 "Сначала выполните zsh build.sh"; exit 1; }
if [[ -e "$target_app" ]]; then
    existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target_app/Contents/Info.plist")
    [[ "$existing_id" == local.bluescreen.mac ]] || { print -u2 "По этому пути находится другое приложение"; exit 1; }
fi
codesign --verify --deep --strict "$source_app"
ditto "$source_app" "$target_app"
codesign --verify --deep --strict "$target_app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target_app"
mdimport "$target_app"
print "Установлено: $target_app"
