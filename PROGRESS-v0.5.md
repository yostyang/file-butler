# v0.5 进度
- [x] 1 性能：直接绘制单元格/增量增删行/TabChrome/显示名缓存 → 拷贝30 ⌘A 30–38 废纸篓17–27 移动37–42 ms（目标<50）
- [x] 2 列表空白处框选（真实 mouseDown 跟踪循环，含纯竖直拖动）
- [x] 3 清理调试计时代码
- [x] 6 DMG：卸载 4 个残留临时镜像；HFS+ + 看门狗，构建 DMG 正常（3.6MB）
- [ ] 4 完整 test.sh + 审查快照 + approve
- [x] 5 基准：cp -c 267ms，ditto 298ms，mv 196ms（2003 项）
- [ ] 7 release.sh 0.5.0
- [ ] 8 拷贝到 /workspace/fb-v05
