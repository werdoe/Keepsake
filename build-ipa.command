#!/bin/bash
# Builds an unsigned IGSaver.ipa next to this script.
# Double-click in Finder, or run:  bash build-ipa.command
cd "$(dirname "$0")" || exit 1
LOG="$PWD/build-ipa.log"
exec > >(tee "$LOG") 2>&1

echo "== IGSaver IPA build $(date) =="

if ! xcodebuild -version >/dev/null 2>&1; then
  echo
  echo "ERROR: xcodebuild isn't working. Install Xcode from the App Store, open it once,"
  echo "then run:  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  echo "FAILED"
  exit 1
fi
xcodebuild -version

rm -rf build Payload IGSaver.ipa
xcodebuild \
  -project IGSaver.xcodeproj \
  -target IGSaver \
  -configuration Release \
  -sdk iphoneos \
  SYMROOT="$PWD/build" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build

APP="build/Release-iphoneos/IGSaver.app"
if [ ! -d "$APP" ]; then
  echo
  echo "FAILED: build didn't produce $APP (see errors above)"
  exit 1
fi

mkdir -p Payload
cp -R "$APP" Payload/
zip -qry IGSaver.ipa Payload
rm -rf Payload

echo
echo "DONE: $PWD/IGSaver.ipa ($(du -h IGSaver.ipa | cut -f1))"
echo "You can close this window."
