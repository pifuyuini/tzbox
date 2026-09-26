#!/bin/sh
set -eu
repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository"
configuration=${1:-release}
binary_directory=$("$repository/scripts/compile.sh" "$configuration")
bundle="$repository/build/TZBox.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_directory/TZBoxApp" "$bundle/Contents/MacOS/TZBox"
if [ -f "$binary_directory/libTZBoxCore.dylib" ]; then
  mkdir -p "$bundle/Contents/Frameworks"
  cp "$binary_directory/libTZBoxCore.dylib" "$bundle/Contents/Frameworks/"
  /usr/bin/codesign --force --sign - "$bundle/Contents/Frameworks/libTZBoxCore.dylib"
fi
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TZBox</string>
<key>CFBundleIdentifier</key><string>dev.tzbox.app</string>
<key>CFBundleName</key><string>TZBox</string>
<key>CFBundleDisplayName</key><string>TZBox</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$bundle/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
echo "$bundle"
