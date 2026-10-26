#!/bin/bash
# 文件管家自动化测试：任何一步失败都会立即中止（发布前必须通过）
#   1. 编译（通用版 + 固定签名）  2. --selftest 文件操作自测
#   3. --uitest 在应用进程内驱动自己的界面（右键菜单、路径栏、新建文件夹+就地重命名、拷贝粘贴、废纸篓+撤销、⌘1-4、⌘F、⇧⌘P）并截图
#   4. 截图与 Tests/golden/ 里人工确认过的基准图对比
#   用法：./test.sh            正常测试
#         ./test.sh --approve  把本次截图设为新的基准图（必须先人工检查截图）
set -euo pipefail
cd "$(dirname "$0")"
OUT=build-test/ui; mkdir -p build-test
APP="build/文件管家.app/Contents/MacOS/FileButler"
restore() { [ -f /tmp/fb-ui-defaults-backup.plist ] && defaults import com.yost.filebutler /tmp/fb-ui-defaults-backup.plist && rm -f /tmp/fb-ui-defaults-backup.plist || true; }
trap restore EXIT
echo "== 1/4 编译 =="; ./build.sh > build-test/build.log 2>&1 || { tail -30 build-test/build.log; echo "编译失败"; exit 1; }
grep -q 'certificate leaf = H"f84b9654f42df2c8bfdd75f7eaf123a7525d060c"' build-test/build.log || { echo "签名身份不对（会导致权限失效）"; exit 1; }
echo "== 2/4 文件操作自测 =="; "$APP" --selftest | tee build-test/selftest.log | grep -E "FAIL|结果"; grep -q "0 失败" build-test/selftest.log
echo "== 3/4 界面测试 =="
"$APP" --uitest "$PWD/$OUT" > build-test/uitest.log 2>&1 & P=$!
for i in $(seq 1 240); do kill -0 $P 2>/dev/null || break; sleep 1; done
if kill -0 $P 2>/dev/null; then kill $P; echo "界面测试超时"; exit 1; fi
wait $P || { grep -E "FAIL" build-test/uitest.log; tail -1 build-test/uitest.log; echo "界面测试失败"; exit 1; }
grep -E "FAIL|界面测试" build-test/uitest.log
echo "== 4/4 截图对比 =="
GOLD=Tests/golden
if [ "${1:-}" = "--approve" ]; then
  mkdir -p $GOLD; rm -f $GOLD/*.png
  cp $OUT/pb-*.png $OUT/pane-list.png $OUT/pane-column.png $OUT/video-preview.png $OUT/list-view.png $GOLD/
  echo "已把本次截图设为基准图：$(ls $GOLD | wc -l | tr -d ' ') 张"
else
  "$APP" --compare "$PWD/$GOLD" "$PWD/$OUT" | tee build-test/compare.log | grep -E "FAIL|对比结果"
  grep -q "0 失败" build-test/compare.log || { echo "截图和基准图不一致；检查 $OUT 后用 ./test.sh --approve 更新基准"; exit 1; }
fi
S=$(grep -o "结果：.*" build-test/selftest.log | head -1); U=$(grep -o "界面测试：[0-9]* 通过，[0-9]* 失败" build-test/uitest.log); C=$(grep -o "对比结果：.*" build-test/compare.log 2>/dev/null || echo "基准图已更新")
printf "自测 %s\n%s\n截图%s\n" "$S" "$U" "$C" > build-test/summary.txt
echo "✅ 全部通过"; cat build-test/summary.txt
