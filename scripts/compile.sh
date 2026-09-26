#!/bin/sh
set -eu
repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository"
configuration=${1:-debug}
case "$configuration" in release|debug) ;; *) echo 'Expected release or debug' >&2; exit 2;; esac
if xcrun --sdk macosx --show-sdk-platform-path >/dev/null 2>&1; then
  swift build --scratch-path "$repository/build/swift" -c "$configuration" >&2
  swift build --scratch-path "$repository/build/swift" -c "$configuration" --show-bin-path
else
  echo 'Using installed swiftc directly (Command Line Tools SwiftPM PlatformPath limitation).' >&2
  sdk=$(xcrun --sdk macosx --show-sdk-path)
  output="$repository/build/native/$configuration"
  mkdir -p "$output" "$repository/build/ModuleCache"
  optimization=-Onone
  if [ "$configuration" = release ]; then optimization=-O; fi
  swiftc -swift-version 5 -sdk "$sdk" -target arm64-apple-macosx14.0 -module-cache-path "$repository/build/ModuleCache" "$optimization" -g -parse-as-library -emit-module -emit-library -enable-testing -module-name TZBoxCore -emit-module-path "$output/TZBoxCore.swiftmodule" -o "$output/libTZBoxCore.dylib" -Xlinker -install_name -Xlinker @rpath/libTZBoxCore.dylib Sources/TZBoxCore/*.swift >&2
  for target in TZBoxApp TZBoxDiagnostics; do
    swiftc -swift-version 5 -sdk "$sdk" -target arm64-apple-macosx14.0 -module-cache-path "$repository/build/ModuleCache" "$optimization" -g -parse-as-library -I "$output" -L "$output" -lTZBoxCore -Xlinker -rpath -Xlinker @executable_path -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$output/$target" Sources/"$target"/*.swift >&2
  done
  echo "$output"
fi
