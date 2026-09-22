## Why

需要一个记录个人资产的小工具：以**万元**为单位维护若干条资产条目（例如「股票 10.5」「流动资金 1.3」），每次改动都自动把**当日总资产**落库，并能按日 / 周 / 月 / 年查看资产变化曲线。

现成的记账 App 要么太重（记账单、分类预算、账本），要么不支持「条目集合 + 每日总资产快照」这个模型——它关心的不是流水，而是**资产总量随时间的走势**。同时用户希望在同一个 Apple 账号的多台设备之间自动保持一致，而不需要手动导出导入。

## What Changes

- 新增资产条目管理：名称、金额（万元）、类别、备注；支持新增、编辑、左滑删除、拖动排序。
- 新增「当日总资产快照」：**任何一次条目改动都会立刻重算总资产并写入本地 SQLite**；同一个自然日只保留一条，重复修改覆盖当天值，历史日期不受影响。
- 新增资产走势曲线：Swift Charts 折线 + 面积图，把每日快照按 **日 / 周 / 月 / 年** 归并，每个桶取该周期最后一次记录；长按可查看某一点的具体数值。
- 新增历史记录列表：逐日列出总资产以及与上一条的增减额，作为曲线的检索补充。
- 新增 iCloud 同步：条目与每日快照写入 iCloud 云盘文件，**快照按年分片**；多设备之间按 `updatedAt` 做 last-writer-wins 合并，删除以墓碑形式传播。
- 同步具备离线容错：iCloud 不可用时整轮跳过，本地数据一个字都不动，改动保留待下次补传。
- **首次启动不写入任何示例数据**，改为空状态里的显式按钮。云端数据是异步回灌的，自动播种必然导致重名重复。

## Capabilities

### New Capabilities

- `asset-tracking`：资产条目的建模与增删改排序，以及「每次改动自动记录当日总资产快照」的落库契约。
- `asset-trend-chart`：按日 / 周 / 月 / 年归并的资产曲线、选中读数交互与历史记录检索。
- `icloud-sync`：跨设备的条目与快照同步，含文件分片布局、冲突裁决、删除传播与离线容错。

### Modified Capabilities

无。这是该工程的第一批规格，`openspec/specs/` 下暂无既有能力。

## Impact

- **新增工程**：`IceRecord`，iOS 18.0+，SwiftUI + Swift Charts，无任何第三方依赖；工程由 `project.yml` 经 xcodegen 生成。
- **本地持久化**：`Library/Application Support/IceRecord/IceRecord.sqlite`，直接用 sqlite3 C API 薄封装，无 ORM。表 `asset_item` / `asset_snapshot` / `app_meta` / `sync_state`。
- **iCloud**：ubiquity container 的 `Documents/IceRecord/`，使用 iCloud Documents 能力，**不使用 CloudKit**（CloudKit 需要自定义 zone 与服务端 schema，正式环境还要手动 Deploy，易触发 `CKError 15 serverRejectedRequest`）。需要付费 Apple Developer 账号；未启用时 App 完全按本地模式运行。
- **测试**：`IceRecordTests`（数据库 / Store 行为 / 日周月年归并 / 同步语义 / 文件分片与合并）与 `IceRecordUITests`（端到端首屏 → 新增条目 → 总资产重算 → 四种曲线 → 设置页）。
- **调试开关**：`--seed-demo-history`（生成演示曲线）、`--use-local-sync-directory`（把云盘换成本地目录，用于在无 iCloud 的模拟器上跑完整文件同步链路）。
