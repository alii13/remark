#!/bin/bash
# build.sh            -> compile + bundle + Developer ID sign (hardened runtime, stable identity)
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

echo "compiling…"
swiftc -O \
  Sources/Theme.swift Sources/AudioCapture.swift Sources/Transcriber.swift \
  Sources/QuestionEngine.swift Sources/MeetingDetector.swift Sources/AppState.swift \
  Sources/ContextStore.swift Sources/Distiller.swift \
  Sources/UI/PanelView.swift Sources/UI/DropdownView.swift Sources/UI/OnboardingView.swift \
  Sources/RemarkApp.swift \
  -o build/remark \
  -framework SwiftUI -framework AppKit -framework AudioToolbox \
  -framework AVFoundation -framework CoreMedia -framework CoreAudio

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/remark "$APP/Contents/MacOS/Remark"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
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
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSMicrophoneUsageDescription</key><string>Remark listens to your meeting so it can suggest questions to ask.</string>
<key>NSAudioCaptureUsageDescription</key><string>Remark records your meeting's audio on your Mac so it can suggest questions to ask.</string>
</dict></plist>
PLIST

echo "signing (Developer ID, hardened runtime)…"
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
