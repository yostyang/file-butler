#!/bin/bash
# 编译通用版（Apple 芯片 + Intel）并打包 DMG
set -e
cd "$(dirname "$0")"
SRC="App.swift Model.swift Controller.swift FileTable.swift Browse.swift Views.swift SizeAnalysis.swift SelfTest.swift"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos13 $SRC -o fb_arm
swiftc -O -parse-as-library -swift-version 5 -target x86_64-apple-macos13 $SRC -o fb_x86
lipo -create fb_arm fb_x86 -output FileButler; rm -f fb_arm fb_x86
A="build/文件管家.app"; rm -rf build; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
cp FileButler "$A/Contents/MacOS/"; cp AppIcon.icns "$A/Contents/Resources/"; cp Info.plist "$A/Contents/"; mkdir -p "$A/Contents/Resources/zh-Hans.lproj"
codesign --force --deep -s - "$A"
mkdir -p build/dmg; cp -R "$A" build/dmg/; ln -s /Applications build/dmg/Applications
hdiutil create -volname "文件管家" -srcfolder build/dmg -ov -format UDZO "build/文件管家.dmg"
echo "完成：build/文件管家.dmg"
