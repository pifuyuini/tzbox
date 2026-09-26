#!/bin/sh
set -eu
repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository"
if [ ! -x build/TZBox.app/Contents/MacOS/TZBox ]; then
  echo 'Build first with ./scripts/build.sh' >&2
  exit 1
fi
mkdir -p tmp
test_root=$(mktemp -d "$repository/tmp/$(date -u +%Y%m%dT%H%M%SZ)-ui-smoke-XXXXXX")
touch "$test_root/.codex-tmp"
echo "UI smoke artifact directory: $test_root"
TZBOX_DATA_DIR="$test_root/data" TZBOX_UI_SMOKE_OUTPUT="$test_root/window.png" "$repository/build/TZBox.app/Contents/MacOS/TZBox" > "$test_root/app.log" 2>&1
if [ ! -s "$test_root/window.png" ]; then
  cat "$test_root/app.log" >&2
  echo "UI smoke failed; evidence retained at $test_root" >&2
  exit 1
fi
echo "Own-window rendering passed: $test_root/window.png"
echo 'Artifacts retained for visual inspection; remove only this marked directory after reviewing its contents.'
