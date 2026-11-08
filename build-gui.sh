#!/bin/bash
# Builds VMForge.app (a native SwiftUI front-end for the vmforge CLI)
set -euo pipefail
cd "$(dirname "$0")"
APP=VMForge.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library gui/VMForgeApp.swift -o "$APP/Contents/MacOS/VMForge"
cp vmforge vmhost.swift vmhost.entitlements "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>VMForge</string>
<key>CFBundleDisplayName</key><string>VMForge</string>
<key>CFBundleIdentifier</key><string>local.vmforge.gui</string>
<key>CFBundleExecutable</key><string>VMForge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force -s - "$APP"
echo "Built $APP — open it with:  open $APP"
