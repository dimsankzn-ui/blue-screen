#!/bin/zsh
set -eu
cd "$(dirname "$0")"
mkdir -p build/BlueScreen.app/Contents/MacOS
xcrun clang -fobjc-arc -mmacosx-version-min=14.2 -c Sources/VirtualDisplay.m -o build/VirtualDisplay.o
xcrun clang -fobjc-arc -mmacosx-version-min=14.2 -framework AppKit -framework CoreGraphics Tools/VirtualDisplayHelper.m build/VirtualDisplay.o -o build/VirtualDisplayHelper
cp build/VirtualDisplayHelper build/BlueScreen.app/Contents/MacOS/VirtualDisplayHelper
codesign --force --sign - --identifier local.bluescreen.display-helper build/BlueScreen.app/Contents/MacOS/VirtualDisplayHelper
xcrun swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macosx14.2 -import-objc-header Sources/VirtualDisplay.h Sources/Diagnostics.swift Sources/SecondScreen.swift Sources/ScreenPreview.swift Sources/VideoEncoder.swift Sources/TVConnection.swift Sources/App.swift build/VirtualDisplay.o -o build/BlueScreen.app/Contents/MacOS/BlueScreen
cp Info.plist build/BlueScreen.app/Contents/Info.plist
mkdir -p build/BlueScreen.app/Contents/Resources
cp Assets/AppIcon.icns build/BlueScreen.app/Contents/Resources/AppIcon.icns
codesign --force --sign - --identifier local.bluescreen.mac build/BlueScreen.app
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.2 Sources/Diagnostics.swift Tests/Checks.swift -o build/checks
build/checks
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.2 -import-objc-header Sources/VirtualDisplay.h Sources/Diagnostics.swift Sources/SecondScreen.swift Tests/VirtualScreenChecks.swift build/VirtualDisplay.o -o build/virtual-screen-checks
