#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swift build -c release -debug-info-format none --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
appName="Vidlib"
bundleID="local.vidlib.app"
if [[ "${1:-}" == "--preview" ]]; then
  appName="Vidlib Preview"
  bundleID="local.vidlib.preview"
fi
app="$PWD/build/$appName.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
iconset="$PWD/build/Vidlib.iconset"
mkdir -p "$iconset"
for points in 16 32 128 256 512; do
  sips -z "$points" "$points" Assets/Vidlib.png --out "$iconset/icon_${points}x${points}.png" >/dev/null
  pixels=$((points * 2))
  sips -z "$pixels" "$pixels" Assets/Vidlib.png --out "$iconset/icon_${points}x${points}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/Vidlib.icns"
cp .build/release/Vidlib "$app/Contents/MacOS/Vidlib"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Vidlib</string>
<key>CFBundleIdentifier</key><string>local.vidlib.app</string>
<key>CFBundleName</key><string>Vidlib</string>
<key>CFBundleDisplayName</key><string>Vidlib</string>
<key>CFBundleIconFile</key><string>Vidlib.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>local.vidlib.clip-selection</string>
<key>UTTypeDescription</key><string>Vidlib catalog selection</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
</dict></array>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundleID" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $appName" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $appName" "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "Built $app"
