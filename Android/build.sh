#!/bin/zsh
set -eu
cd "$(dirname "$0")"
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
jdk="${JAVA_HOME:-$(/usr/libexec/java_home)}"
bt="$sdk/build-tools/35.0.0"
platform="$sdk/platforms/android-34/android.jar"
mkdir -p build/classes build/dex build/tests
"$jdk/bin/javac" --release 8 -Xlint:-options -encoding UTF-8 -cp "${platform}:lib/*" -d build/classes src/local/bluescreen/tv/*.java
"$jdk/bin/javac" --release 8 -cp build/classes -d build/tests Tests/WireChecks.java
"$jdk/bin/java" -cp build/classes:build/tests local.bluescreen.tv.WireChecks
"$jdk/bin/jar" cf build/classes.jar -C build/classes .
JAVA_HOME="$jdk" "$bt/d8" --lib "$platform" --min-api 30 --output build/dex build/classes.jar lib/*.jar
"$bt/aapt2" compile --dir res -o build/resources.zip
"$bt/aapt2" link -I "$platform" --manifest AndroidManifest.xml -R build/resources.zip -A assets --min-sdk-version 30 --target-sdk-version 34 -o build/unsigned.apk
zip -q -j build/unsigned.apk build/dex/classes*.dex
"$bt/zipalign" -f -p 4 build/unsigned.apk build/aligned.apk
if [[ ! -f build/development.keystore ]]; then
    "$jdk/bin/keytool" -genkeypair -keystore build/development.keystore -storepass android -keypass android -alias bluescreen -keyalg RSA -keysize 2048 -validity 3650 -dname "CN=BlueScreen Local Development" -noprompt
fi
JAVA_HOME="$jdk" "$bt/apksigner" sign --ks build/development.keystore --ks-key-alias bluescreen --ks-pass pass:android --out build/BlueScreen-TV.apk build/aligned.apk
JAVA_HOME="$jdk" "$bt/apksigner" verify build/BlueScreen-TV.apk
echo "PASS: Android TV APK built and signature verified"
