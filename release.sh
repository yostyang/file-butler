#!/bin/bash
# 发布：必须先通过 test.sh，然后改版本号、重新编译签名、安装、打包、提交、推送、建 GitHub Release
# 用法：./release.sh 0.4.3 "发布说明（中文，可多行）"
set -euo pipefail
cd "$(dirname "$0")"
V="${1:-}"; NOTES="${2:-}"
[[ "$V" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "版本号格式不对：$V"; exit 1; }
GH="${GH:-$(command -v gh 2>/dev/null || echo "$HOME/.local/bin/gh")}"
[ -x "$GH" ] || { echo "找不到 gh 命令（可通过 GH=/path/to/gh 指定）"; exit 1; }
if [ -n "$(git status --porcelain)" ]; then
  echo "❌ 工作区有未提交的改动，请先提交或清理后再发布"
  git status -s
  exit 1
fi
B=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" -c "Set :CFBundleVersion $B" Info.plist
FB_REQUIRE_SIGNING=1 ./test.sh || { echo "❌ 测试没通过，停止发布"; git checkout Info.plist; exit 1; }
echo "== 编译正式版（不含测试代码）并打包 DMG =="
./build.sh > build-test/release-build.log 2>&1 || { tail -30 build-test/release-build.log; echo "❌ 正式版编译失败"; git checkout Info.plist; exit 1; }
CERT_HASH="${FB_SIGNING_CERT_HASH:-f84b9654f42df2c8bfdd75f7eaf123a7525d060c}"
grep -q "certificate leaf = H\"$CERT_HASH\"" build-test/release-build.log || { echo "❌ 正式版签名身份不对"; git checkout Info.plist; exit 1; }
osascript -e 'quit app "文件管家"' || true
for i in $(seq 1 20); do pgrep -x FileButler >/dev/null || break; sleep 0.5; done
pgrep -x FileButler >/dev/null && { echo "文件管家没有正常退出，停止发布"; git checkout Info.plist; exit 1; }
rm -rf "/Applications/文件管家.app" && cp -R "build/文件管家.app" /Applications/ && open "/Applications/文件管家.app"
rm -f ~/Desktop/文件管家-*.dmg; cp "build/文件管家.dmg" ~/Desktop/"文件管家-$V.dmg"; cp "build/文件管家.dmg" "/tmp/File-Butler-$V.dmg"
sleep 5; pgrep -x FileButler >/dev/null || { echo "安装后没有启动"; exit 1; }
git add Info.plist && git commit -qm "v$V" && git push -q
SUMMARY=$(cat build-test/summary.txt)
"$GH" release create "v$V" "/tmp/File-Butler-$V.dmg" --repo yostyang/file-butler --title "文件管家 $V" --notes "$NOTES

---
自动化测试（发布前通过）：
$SUMMARY"
H1=$(shasum -a 256 "/tmp/File-Butler-$V.dmg" | cut -d' ' -f1)
H2=$(curl -sL "https://github.com/yostyang/file-butler/releases/download/v$V/File-Butler-$V.dmg" | shasum -a 256 | cut -d' ' -f1)
rm -f "/tmp/File-Butler-$V.dmg"
[ "$H1" = "$H2" ] && echo "✅ 发布完成，下载校验一致 $H1" || { echo "下载校验不一致"; exit 1; }
