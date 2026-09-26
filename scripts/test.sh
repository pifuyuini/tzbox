#!/bin/sh
set -eu
repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository"
mkdir -p "$repository/tmp"
test_root=$(mktemp -d "$repository/tmp/$(date -u +%Y%m%dT%H%M%SZ)-tests-XXXXXX")
touch "$test_root/.codex-tmp"
cleanup() { "$repository/.venv/bin/python" "$repository/scripts/cleanup_test_root.py" "$repository" "$test_root"; }
trap cleanup EXIT
export TZBOX_TEST_ROOT="$test_root"
if xcrun --sdk macosx --show-sdk-platform-path >/dev/null 2>&1; then
  swift test --scratch-path "$repository/build/swift"
  binary_directory=$(swift build --scratch-path "$repository/build/swift" --show-bin-path)
else
  binary_directory=$("$repository/scripts/compile.sh" debug)
  sdk=$(xcrun --sdk macosx --show-sdk-path)
  swiftc -swift-version 5 -sdk "$sdk" -target arm64-apple-macosx14.0 -module-cache-path "$repository/build/ModuleCache" -parse-as-library -emit-module -emit-library -module-name TZBoxTestSupport -emit-module-path "$binary_directory/TZBoxTestSupport.swiftmodule" -o "$binary_directory/libTZBoxTestSupport.dylib" -Xlinker -install_name -Xlinker @rpath/libTZBoxTestSupport.dylib Tests/Support/TZBoxTestSupport.swift
  "$repository/.venv/bin/python" scripts/generate_selftest_runner.py > "$binary_directory/SelfTestMain.swift"
  swiftc -swift-version 5 -sdk "$sdk" -target arm64-apple-macosx14.0 -module-cache-path "$repository/build/ModuleCache" -parse-as-library -I "$binary_directory" -L "$binary_directory" -lTZBoxCore -lTZBoxTestSupport -Xlinker -rpath -Xlinker @executable_path -o "$binary_directory/TZBoxSelfTests" Tests/TZBoxCoreTests/*.swift "$binary_directory/SelfTestMain.swift"
  "$binary_directory/TZBoxSelfTests"
fi
PYTHONDONTWRITEBYTECODE=1 "$repository/.venv/bin/python" -m unittest discover -s Tests/fixtures -p 'test_*.py'
if [ "${1:-}" = --native-probe ]; then
  "$repository/.venv/bin/python" scripts/make_probe_bundle.py "$binary_directory/TZBoxDiagnostics" "$test_root"
  "$binary_directory/TZBoxDiagnostics" native-probe "$test_root/TZBoxProbe.app" "$test_root/probe-output.json" America/New_York
fi
