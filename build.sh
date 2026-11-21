#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/dist/划词即听·声音版.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PWD/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
xcrun --sdk macosx swiftc -target "$(uname -m)-apple-macos13.0" \
    -swift-version 5 -O -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -framework AppKit -framework AVFoundation -framework ApplicationServices \
    Sources/Selection.swift Sources/Accessibility.swift Sources/App.swift Sources/main.swift \
    -o "$APP/Contents/MacOS/WordSpeaker"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>划词即听·声音版</string>
    <key>CFBundleDisplayName</key><string>划词即听·声音版</string>
    <key>CFBundleIdentifier</key><string>local.wordspeaker.voice</string>
    <key>CFBundleExecutable</key><string>WordSpeaker</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.2</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - --identifier local.wordspeaker.voice "$APP"
print "已生成：$APP"
