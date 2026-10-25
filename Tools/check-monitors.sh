#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
[[ -f build/VirtualDisplay.o && -f build/VirtualDisplayHelper ]] || { print -u2 "Run zsh build.sh first"; exit 1; }
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.2 -import-objc-header Sources/VirtualDisplay.h Sources/DisplayMode.swift Sources/Diagnostics.swift Sources/SecondScreen.swift Sources/ScreenPreview.swift Sources/VideoEncoder.swift Sources/TVConnection.swift Sources/Presence.swift Sources/MonitorLibrary.swift Tests/MonitorChecks.swift build/VirtualDisplay.o -o build/monitor-checks
build/monitor-checks
