#!/bin/bash
# 编译通用版（Apple 芯片 + Intel）并打包 DMG
set -e
cd "$(dirname "$0")"
SRC="App.swift Model.swift Controller.swift FileTable.swift Browse.swift Views.swift SizeAnalysis.swift SelfTest.swift Bench.swift Menus.swift"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos13 $SRC -o fb_arm
swiftc -O -parse-as-library -swift-version 5 -target x86_64-apple-macos13 $SRC -o fb_x86
lipo -create fb_arm fb_x86 -output FileButler; rm -f fb_arm fb_x86
A="build/文件管家.app"; rm -rf build; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
cp FileButler "$A/Contents/MacOS/"; cp AppIcon.icns "$A/Contents/Resources/"; cp Info.plist "$A/Contents/"; mkdir -p "$A/Contents/Resources/zh-Hans.lproj"
# 用本机固定的自签名证书签名：签名要求（identifier + 证书）每次构建都一样，
# macOS 的隐私授权（完全磁盘访问等）在更新后依然有效。没有证书时退回临时签名。
KC="$HOME/.filebutler-signing/signing.keychain-db"
if [ -f "$KC" ] && [ -f "$HOME/.filebutler-signing/pass" ]; then
  security unlock-keychain -p "$(cat "$HOME/.filebutler-signing/pass")" "$KC"
  codesign --force --deep --keychain "$KC" -s "FileButler Local Signing" -i com.yost.filebutler "$A"
else
  codesign --force --deep -s - "$A"
fi
codesign -dr - "$A" 2>&1 | tail -1
mkdir -p build/dmg; cp -R "$A" build/dmg/; ln -s /Applications build/dmg/Applications
hdiutil create -volname "文件管家" -srcfolder build/dmg -ov -format UDZO "build/文件管家.dmg"
echo "完成：build/文件管家.dmg"
