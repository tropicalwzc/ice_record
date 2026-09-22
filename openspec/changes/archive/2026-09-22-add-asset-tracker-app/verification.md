# Verification

Status: complete and archived.

## Automated evidence

| Command | Result |
| --- | --- |
| `xcodebuild test -project IceRecord.xcodeproj -scheme IceRecord -destination 'id=<iPhone 16 Pro, iOS 18.4>' -derivedDataPath ./build` | `** TEST SUCCEEDED **`，56 个测试（53 单元 + 3 UI），0 失败 |
| 上面同一条命令的单元测试子集 `-only-testing:IceRecordTests` | 53 个测试，0 失败 |

测试分布：

| 测试文件 | 数量 | 覆盖 |
| --- | --- | --- |
| `AssetStoreTests` | 14 | 建表与迁移、同日快照就地更新、历史日期不被污染、删除归零、排序持久化、示例数据不重复写入 |
| `TrendAggregatorTests` | 9 | 日 / 周 / 月 / 年四种归并、点数上限、金额解析与展示、自然日键往返 |
| `SyncEngineTests` | 16 | 推送清脏、墓碑推送、远端插入 / 覆盖 / 保留、远端删除传播、快照按天合并、部分失败不阻断、不可用时跳过、推送失败保留脏标记 |
| `FileSyncTransportTests` | 14 | 按年分片、只重写改动年份、单年体积上界、编解码往返、坏文件容错、LWW 合并、双设备互不覆盖、指纹增量 |
| `AppFlowUITests` | 3 | 端到端首屏 → 新增条目 → 总资产重算 → 四种曲线 → 长按气泡 → 设置页 |

## Measured figures

| 指标 | 实测值 | 来源 |
| --- | --- | --- |
| 一年 365 天每日快照的云端文件体积 | **4594 字节**（`snapshots-2026.json.deflate`） | `testEachYearFileStaysSmall` |
| App 实际写出的条目文件 | 322 字节（3 条条目） | 模拟器容器内 `DebugSyncDirectory/items.json.deflate` |
| App 实际写出的快照文件 | 121 字节（1 天） | 模拟器容器内 `DebugSyncDirectory/snapshots-2026.json.deflate` |

体积有上界正是「按年分片」要解决的问题：单文件随年份线性增长被切断，十年也只有几十 KB。

## Verified in the simulator

- **完整文件同步链路**：用 Debug 开关 `--use-local-sync-directory` 把云盘换成本地目录，App 真实写出 `items.json.deflate` 与 `snapshots-2026.json.deflate`，并用 Python 以 `zlib.decompress(data, -15)` 成功解开，确认内容是预期的紧凑 `[SyncRecord]` JSON。
- **指纹增量生效**：第二次启动的日志为「扫描 2 个文件，下载 0 个（跳过未变化的 2 个）」。
- **卸载重装后从云端完整回灌且不重复**：卸载 App → 重装 → 启动后本地精确恢复 3 条条目（股票 10.5 / 流动资金 1.3 / Fund 2.5）与 1 条快照，没有出现重复行。这一条直接覆盖了「自动播种导致重名重复」的回归。
- **日志可用**：`log stream --level debug --predicate 'subsystem == "com.icerecord.app"'` 能完整看到同步各步骤；第一次不加 `--level debug` 时确实什么都看不到，已在 README 中记录。
- **曲线对齐**：用 `Tools/crop_png.swift` 把走势页截图局部放大，逐帧核对数据点与纵轴刻度；修复前 8/30 的实际值 19.91 万被画在 16.7 万的位置，修复后正确贴在 20 刻度线附近。
- **气泡**：在浅色与深色模式下分别抓图确认气泡完整可见、浅灰底黑字带边框；选中位于绘图区上半部分的点时气泡自动向下弹出。
- **数值正确性**：气泡显示的 9/10 = 19.19 万、9/11 = 19.12 万（较前一日 -0.07 万）与数据库中的 `asset_snapshot` 逐条核对一致。

## Not verifiable in this environment

- **真正的跨设备 iCloud 云盘同步**：需要登录 iCloud 的真机，且 ubiquity 容器要在开发者账号下能建出来。当前使用的模拟器包内 entitlements 为空（没有配置 Team），因此拿不到容器。
  - 缓解措施：存储被抽象为 `CloudFileStore`，`FileSyncTransport` 中只剩编解码、分片、合并、指纹这几件事，全部被本地目录实现覆盖；未验证面仅剩 `NSFileCoordinator` 与系统 API 调用本身。
  - 残留风险：云盘按需下载行为、以及两台真机之间的实际收敛速度。
- **`NSFileCoordinator` 在真实 iCloud 写入竞争下的行为**：本地目录实现不会产生协调冲突，这条路径未被触发。

## Known limitations accepted

- 冲突裁决依赖设备墙钟（`updatedAt`）。两台设备时钟严重偏差时会做出错误裁决；个人记账场景下接受，若需要更严格语义要换成设备序号 + 逻辑时钟，那会改变规格。
- 云盘文件是「读-改-写」而非原子追加，两台设备几乎同时写同一年文件时存在丢失一次更新的窗口。缓解：写入前先读并合并，且每台设备本地仍保有完整数据，下一轮同步会把落后的一方重新推上去。
- 墓碑不清理，删除的条目会留下永久记录。个人条目数量级下可忽略。
- 未登录 iCloud 时同步整轮跳过，数据只在本机。这是设计选择（见 `specs/icloud-sync/spec.md`），不是缺陷。
