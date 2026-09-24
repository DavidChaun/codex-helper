#!/bin/sh
set -eu
cd "$(dirname "$0")"
app="Codex Helper.app"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
mkdir -p "$app/Contents/Frameworks"
mkdir -p ".build/swift-cache"
swiftc -swift-version 5 -module-cache-path ".build/swift-cache" -F Vendor/Sparkle \
  -framework AppKit -framework Network -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  CodexQuotaBar.swift WorkBuddyAccountPool.swift WorkBuddyClient.swift WorkBuddyProxy.swift TraeClient.swift TraeAccountPool.swift -o ".build/CodexQuotaBar"
cp ".build/CodexQuotaBar" "$app/Contents/MacOS/CodexQuotaBar"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
ditto Vendor/Sparkle/Sparkle.framework "$app/Contents/Frameworks/Sparkle.framework"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexQuotaBar</string>
<key>CFBundleIdentifier</key><string>local.codex.quota-bar</string>
<key>CFBundleName</key><string>Codex Helper</string>
<key>CFBundleDisplayName</key><string>Codex Helper</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>43</string>
<key>CFBundleShortVersionString</key><string>1.8.4</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>SUFeedURL</key><string>https://davidchaun.github.io/codex-helper/appcast.xml</string>
<key>SUPublicEDKey</key><string>VGhhhfps2/a+eShyKEm80nLUdwdANy9eYTVSaiYytoM=</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUAutomaticallyUpdate</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
"$app/Contents/MacOS/CodexQuotaBar" --self-test
