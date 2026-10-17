#!/bin/bash
# Builds Keepsake, signs it for the App Store with the App Store Connect API key
# (Xcode manages the certificates and profiles), and uploads it to TestFlight.
set -uo pipefail
ROOT="$PWD"
OUT="$ROOT/tf-out"
ENV_FILE="$RUNNER_TEMP/asc/asc.env"
mkdir -p "$OUT" "$RUNNER_TEMP/asc"
echo "running" > "$OUT/status.txt"
git rev-parse HEAD > "$OUT/commit.txt"
fail() { echo "failed: $1" > "$OUT/status.txt"; echo "FAILED: $1"; exit 1; }

# 1. Newest released Xcode (App Store uploads need the current SDK).
XCODE=$(ls -d /Applications/Xcode_*.app 2>/dev/null | grep -viE 'beta|_rc|release.candidate' | sort -V | tail -1)
[ -n "$XCODE" ] && sudo xcode-select -s "$XCODE"
xcodebuild -version | tee "$OUT/xcode.txt"

# 2. App Store Connect: key, bundle IDs, team, app record, TestFlight group.
python3 -m venv "$RUNNER_TEMP/asc/venv" >/dev/null && "$RUNNER_TEMP/asc/venv/bin/pip" -q install 'pyjwt[crypto]' requests \
  || fail "couldn't install the App Store Connect helper"
PY="$RUNNER_TEMP/asc/venv/bin/python"
"$PY" Config/testflight/asc.py setup "$OUT" "$ENV_FILE" || fail "$(cat "$OUT/problem.txt" 2>/dev/null || echo 'App Store Connect setup')"
source "$ENV_FILE"

scrub() { sed -e "s/${ASC_KEY_ID}/[key-id]/g" -e "s/${ASC_ISSUER_ID}/[issuer-id]/g"; }
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
BUILD_NUMBER=$(date -u +%y%m%d%H%M)
echo "Build number: $BUILD_NUMBER" >> "$OUT/summary.txt"

# 3. Archive (signed by Xcode with automatic signing).
ARCHIVE="$RUNNER_TEMP/Keepsake.xcarchive"
xcodebuild archive \
  -project IGSaver.xcodeproj -scheme IGSaver -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  "${AUTH[@]}" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" 2>&1 | scrub > "$OUT/archive.log"
ARCHIVE_STATUS=${PIPESTATUS[0]}
grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" "$OUT/archive.log" | sort -u | head -40 >> "$OUT/summary.txt"
[ "$ARCHIVE_STATUS" -eq 0 ] && [ -d "$ARCHIVE" ] || fail "archive (see archive.log)"

# 4. Export for App Store Connect and upload.
sed "s/TEAM_ID/$TEAM_ID/" Config/testflight/ExportOptions.plist > "$RUNNER_TEMP/ExportOptions.plist"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportOptionsPlist "$RUNNER_TEMP/ExportOptions.plist" -exportPath "$RUNNER_TEMP/export" \
  "${AUTH[@]}" 2>&1 | scrub > "$OUT/upload.log"
UPLOAD_STATUS=${PIPESTATUS[0]}
grep -iE "error|upload succeeded|EXPORT (SUCCEEDED|FAILED)|Uploaded" "$OUT/upload.log" | sort -u | head -40 >> "$OUT/summary.txt"
[ "$UPLOAD_STATUS" -eq 0 ] || fail "upload (see upload.log)"

sleep 20
"$PY" Config/testflight/asc.py report "$OUT" "$ENV_FILE" || true
echo "uploaded $BUILD_NUMBER" > "$OUT/status.txt"
