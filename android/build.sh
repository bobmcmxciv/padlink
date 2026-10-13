#!/bin/bash
# Builds build/PadLink.apk with the plain SDK command line tools (aapt2 / javac / d8 / apksigner), no Gradle.
#   ANDROID_SDK   SDK root with build-tools and platforms/android-35 (default ~/android-sdk)
#   JAVA_HOME     JDK 17+ (default: $ANDROID_SDK/jdk17/Contents/Home if present)
#   PADLINK_KEYSTORE  signing keystore, created on first build (default $ANDROID_SDK/padlink-debug.keystore)
set -eu
cd "$(dirname "$0")"
SDK="${ANDROID_SDK:-$HOME/android-sdk}"
BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
JAR="$SDK/platforms/android-35/android.jar"
if [ -z "${JAVA_HOME:-}" ] && [ -d "$SDK/jdk17/Contents/Home" ]; then JAVA_HOME="$SDK/jdk17/Contents/Home"; fi
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"
KS="${PADLINK_KEYSTORE:-$SDK/padlink-debug.keystore}"
OUT="$PWD/build"
mkdir -p "$OUT"
find "$OUT" -mindepth 1 -delete
mkdir -p "$OUT/gen" "$OUT/classes" "$OUT/dex"

"$BT/aapt2" compile --dir res -o "$OUT/res.zip"
"$BT/aapt2" link -o "$OUT/base.apk" -I "$JAR" --manifest AndroidManifest.xml "$OUT/res.zip" \
  --java "$OUT/gen" --min-sdk-version 31 --target-sdk-version 35 --version-code 1 --version-name 1.0.0
javac -encoding UTF-8 --release 11 -Xlint:-options -classpath "$JAR" -d "$OUT/classes" \
  $(find src "$OUT/gen" -name '*.java')
"$BT/d8" --release --min-api 31 --lib "$JAR" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')
cp "$OUT/base.apk" "$OUT/unsigned.apk"
(cd "$OUT/dex" && zip -q -j "$OUT/unsigned.apk" classes.dex)
"$BT/zipalign" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
[ -f "$KS" ] || keytool -genkeypair -keystore "$KS" -storepass android -keypass android -alias padlink \
  -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=PadLink" >/dev/null 2>&1
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android --out "$OUT/PadLink.apk" "$OUT/aligned.apk"
ls -l "$OUT/PadLink.apk"
