#!/bin/bash
# 发布：必须先通过 test.sh，然后改版本号、重新编译签名、安装、打包、提交、推送、建 GitHub Release
# 用法：./release.sh 0.4.3 "发布说明（中文，可多行）"
set -euo pipefail
cd "$(dirname "$0")"
V="$1"; NOTES="${2:-}"
[[ "$V" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "版本号格式不对：$V"; exit 1; }
B=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" -c "Set :CFBundleVersion $B" Info.plist
./test.sh || { echo "❌ 测试没通过，停止发布"; git checkout Info.plist; exit 1; }
osascript -e 'quit app "文件管家"' || true
for i in $(seq 1 20); do pgrep -x FileButler >/dev/null || break; sleep 0.5; done
pgrep -x FileButler >/dev/null && { echo "文件管家没有正常退出，停止发布"; exit 1; }
rm -rf "/Applications/文件管家.app" && cp -R "build/文件管家.app" /Applications/ && open "/Applications/文件管家.app"
rm -f ~/Desktop/文件管家-*.dmg; cp "build/文件管家.dmg" ~/Desktop/"文件管家-$V.dmg"; cp "build/文件管家.dmg" "/tmp/File-Butler-$V.dmg"
sleep 5; pgrep -x FileButler >/dev/null || { echo "安装后没有启动"; exit 1; }
git add -A && git commit -qm "v$V" && git push -q
SUMMARY=$(cat build-test/summary.txt)
~/.local/bin/gh release create "v$V" "/tmp/File-Butler-$V.dmg" --repo yostyang/file-butler --title "文件管家 $V" --notes "$NOTES

---
自动化测试（发布前通过）：
$SUMMARY"
H1=$(shasum -a 256 "/tmp/File-Butler-$V.dmg" | cut -d' ' -f1)
H2=$(curl -sL "https://github.com/yostyang/file-butler/releases/download/v$V/File-Butler-$V.dmg" | shasum -a 256 | cut -d' ' -f1)
[ "$H1" = "$H2" ] && echo "✅ 发布完成，下载校验一致 $H1" || { echo "下载校验不一致"; exit 1; }
