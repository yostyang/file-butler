#!/bin/bash
# 编译通用版（Apple 芯片 + Intel）并打包 DMG
set -e
cd "$(dirname "$0")"
SRC="App.swift Transfer.swift IconCollection.swift UITestBasics.swift Model.swift Controller.swift FileTable.swift Browse.swift Views.swift SizeAnalysis.swift SelfTest.swift Bench.swift Menus.swift UITest.swift Media.swift"
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
[ -n "${NODMG:-}" ] && exit 0
rm -rf build/dmg; mkdir -p build/dmg; cp -R "$A" build/dmg/; ln -s /Applications build/dmg/Applications
# hdiutil 偶尔会卡住（之前留下的临时镜像没卸载、APFS 临时卷挂起）。
# 用 HFS+、带看门狗：超过 180 秒只结束本脚本自己起的 hdiutil，并卸载它留下的临时镜像，再重试一次。
mkdmg() {
  rm -f "build/文件管家.dmg"
  hdiutil create -volname "文件管家" -fs HFS+ -srcfolder build/dmg -ov -format UDZO "build/文件管家.dmg" &
  local P=$! t=0
  while kill -0 $P 2>/dev/null; do sleep 1; t=$((t+1)); [ $t -ge 180 ] && { echo "hdiutil 超时，结束进程 $P"; kill $P; sleep 2; break; }; done
  wait $P 2>/dev/null && [ -s "build/文件管家.dmg" ] && hdiutil verify "build/文件管家.dmg" >/dev/null 2>&1
}
cleanup_imgs() {   # 只卸载没有挂载点、名字是「文件管家」临时卷的镜像
  for d in $(diskutil list | awk '/\(disk image\)/{print $1}'); do
    diskutil list "$d" | grep -q "文件管家" && diskutil eject "$d" >/dev/null 2>&1 || true
  done
}
mkdmg || { cleanup_imgs; echo "重试 DMG 打包"; mkdmg || { echo "DMG 打包失败"; exit 1; }; }
echo "完成：build/文件管家.dmg"
