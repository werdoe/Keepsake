#!/bin/bash
# Pushes the TestFlight run's summary and logs (no secrets) to the testflight-status branch.
set -e
OUT="$PWD/tf-out"
mkdir -p "$OUT"
[ -s "$OUT/status.txt" ] && grep -q running "$OUT/status.txt" && echo "failed: stopped early" > "$OUT/status.txt"
[ -s "$OUT/status.txt" ] || echo "failed: before start" > "$OUT/status.txt"
cd "$OUT"
git init -q -b testflight-status
git config user.name "github-actions"
git config user.email "github-actions@users.noreply.github.com"
git add -A
git commit -qm "TestFlight run ${GITHUB_RUN_NUMBER}: $(cat status.txt)"
git push -qf "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" testflight-status
