#!/bin/bash
# build.sh            -> fetch deps + compile + bundle + Developer ID sign (hardened runtime)
# build.sh notarize  -> the above, then notarize + staple + install to /Applications
set -e
cd "$(dirname "$0")"
mkdir -p build

# Code signing. Defaults to ad-hoc ("-") so `bash build.sh` works on a fresh clone.
# For the audio tap and Keychain to work without prompts, and for notarization, set a real
# Developer ID in your shell (see the README "Building" section):
#   REMARK_SIGN_IDENTITY  : your "Developer ID Application: …" identity (name or SHA-1 hash)
#   REMARK_NOTARY_PROFILE : a notarytool keychain profile (xcrun notarytool store-credentials)
IDENTITY="${REMARK_SIGN_IDENTITY:--}"
BUNDLE_ID="${REMARK_BUNDLE_ID:-com.shekh.remark}"
NOTARY_PROFILE="${REMARK_NOTARY_PROFILE:-remark}"
APP=build/Remark.app

# On-device transcription runs through sherpa-onnx. Fetch the pinned prebuilt universal2 library
# (Apple Silicon + Intel) once and cache it under vendor/ (git-ignored).
SHERPA_VER=2.0.3
SHERPA=vendor/sherpa-onnx
if [ ! -f "$SHERPA/lib/libsherpa-onnx-c-api.dylib" ]; then
  echo "fetching sherpa-onnx $SHERPA_VER…"
  rm -rf "$SHERPA"; mkdir -p "$SHERPA"
  curl -fsSL "https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VER}/sherpa-onnx-v${SHERPA_VER}-osx-universal2-shared.tar.bz2" -o /tmp/sherpa.tar.bz2
  tar xf /tmp/sherpa.tar.bz2 -C "$SHERPA" --strip-components=1
  rm -f /tmp/sherpa.tar.bz2
fi

echo "compiling…"
swiftc -O \
  Sources/Theme.swift Sources/AudioCapture.swift Sources/Recognizer.swift Sources/SherpaOnnx.swift \
  Sources/QuestionEngine.swift Sources/MeetingDetector.swift Sources/AppState.swift \
  Sources/ContextStore.swift Sources/Distiller.swift Sources/Logger.swift Sources/Paths.swift Sources/Setup.swift \
  Sources/UI/PanelView.swift Sources/UI/DropdownView.swift Sources/UI/SetupView.swift \
  Sources/RemarkApp.swift Sources/Updater.swift \
  -import-objc-header "$SHERPA/include/sherpa-onnx/c-api/c-api.h" -I "$SHERPA/include" \
  -L "$SHERPA/lib" -lsherpa-onnx-c-api \
  -F vendor/sparkle -framework Sparkle \
  -o build/remark \
  -framework SwiftUI -framework AppKit -framework AudioToolbox \
  -framework AVFoundation -framework CoreMedia -framework CoreAudio \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp build/remark "$APP/Contents/MacOS/Remark"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# the recognizer links these two dylibs; ship them inside the bundle
cp "$SHERPA/lib/libsherpa-onnx-c-api.dylib" "$SHERPA/lib/libonnxruntime.dylib" "$APP/Contents/Frameworks/"
# Sparkle (auto-update) framework
cp -R vendor/sparkle/Sparkle.framework "$APP/Contents/Frameworks/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Remark</string>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
<key>CFBundleName</key><string>Remark</string>
<key>CFBundleDisplayName</key><string>Remark</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>${REMARK_BUILD:-1}</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSMicrophoneUsageDescription</key><string>Remark listens to your meeting so it can suggest questions to ask.</string>
<key>NSAudioCaptureUsageDescription</key><string>Remark records your meeting's audio on your Mac so it can suggest questions to ask.</string>
<key>SUFeedURL</key><string>https://raw.githubusercontent.com/alii13/remark/main/appcast.xml</string>
<key>SUPublicEDKey</key><string>r920y70cYrwzbsyqHJJSm4Mf0ozCf7TCRllE/Lz5dS0=</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict></plist>
PLIST

echo "signing (Developer ID, hardened runtime)…"
# Sparkle's nested helpers must be signed (with our Team ID) deepest-first, before the framework.
SF="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SF/Versions/B/XPCServices/Downloader.xpc"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SF/Versions/B/XPCServices/Installer.xpc"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SF/Versions/B/Autoupdate"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SF/Versions/B/Updater.app"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SF"
# Sign the embedded dylibs (same Team ID, so hardened-runtime library validation accepts them).
for dylib in "$APP"/Contents/Frameworks/*.dylib; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$dylib"
done
codesign --force --options runtime --timestamp \
  --entitlements entitlements.plist \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "built + signed $APP"

if [ "$1" = "notarize" ]; then
  echo "notarizing (profile: $NOTARY_PROFILE)…"
  ZIP=build/Remark.zip
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  echo "notarized + stapled."
  # install to /Applications (replace any prior copy)
  rm -rf /Applications/Remark.app
  cp -R "$APP" /Applications/Remark.app
  echo "installed to /Applications/Remark.app"
fi
