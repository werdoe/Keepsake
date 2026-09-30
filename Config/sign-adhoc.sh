#!/bin/bash
# Unsigned builds (CODE_SIGNING_ALLOWED=NO) carry no entitlements, but SideStore reads them from
# the app to set up the shared app group. Ad-hoc sign the extensions and app with their entitlements.
# Normal signed builds from Xcode skip this.
set -e
if [ "${CODE_SIGNING_ALLOWED}" != "NO" ]; then
  echo "Signing handled by Xcode; skipping ad-hoc signing."
  exit 0
fi
APP="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
CONFIG="${PROJECT_DIR}/Config"
for appex in "${APP}"/PlugIns/*.appex; do
  [ -d "$appex" ] || continue
  name=$(basename "$appex" .appex)
  if [ -f "${CONFIG}/${name}.entitlements" ]; then
    codesign --force --sign - --entitlements "${CONFIG}/${name}.entitlements" "$appex"
  else
    codesign --force --sign - "$appex"
  fi
done
codesign --force --sign - --entitlements "${CONFIG}/IGSaver.entitlements" "$APP"
echo "Ad-hoc signed ${APP} with entitlements."
