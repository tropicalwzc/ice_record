# 记账本（IceRecord）

一个用 SwiftUI 写的极简资产管理 App，最低支持 **iOS 18.0**。

- 资产条目以 **万元** 为单位记录（例如「股票 10.5」「流动资金 1.3」）。
- **每次增 / 删 / 改 / 排序，都会立刻重算当天的总资产，并写入本地 SQLite**（同一个自然日只保留一条，重复修改覆盖当天值）。
- 「走势」页用 Swift Charts 画资产曲线，支持 **按日 / 周 / 月 / 年** 统计；可在「总资产 / 复合 / 单个类别」之间切换，
  复合模式用分组柱状图展示每期各模块的**变化量**，并列出本周期各模块的变化幅度；下面还有历史记录方便检索。
- 可选 **iCloud 同步**：同一个 Apple 账号下的设备自动看到相同的条目和每日快照。

## 运行

```bash
# 1. 用 xcodegen 生成工程（改了 Sources 目录或 project.yml 后重新执行）
xcodegen generate

# 2. 打开工程
open IceRecord.xcodeproj
```

选一个 iOS 18 及以上的模拟器直接运行即可，无需任何第三方依赖。

> 工程文件 `IceRecord.xcodeproj` 是由 `project.yml` 生成的，新增 Swift 文件后跑一次 `xcodegen generate` 就会自动加进 target。

### 开启 iCloud 同步（需要付费 Apple Developer 账号）

工程里 iCloud 的配置已经写好了，和 `ice reader` 项目里验证过能用的那套保持一致：

```yaml
com.apple.developer.icloud-services: [CloudDocuments]
com.apple.developer.icloud-container-identifiers: []      # 留空 = 用默认容器
com.apple.developer.ubiquity-container-identifiers: []
com.apple.developer.ubiquity-kvstore-identifier: $(TeamIdentifierPrefix)$(CFBundleIdentifier)
```

你只需要：

1. 打开 `project.yml`，把 `DEVELOPMENT_TEAM: ""` 换成你的 Team ID
   （在 [developer.apple.com](https://developer.apple.com/account) → Membership 里看），然后 `xcodegen generate`。
   或者直接在 Xcode 里 target → Signing & Capabilities 选中你的 Team。
2. 确认 target → Signing & Capabilities 里有 **iCloud**（勾 iCloud Documents 即可，**不需要** CloudKit）。
3. 真机登录 iCloud 后运行。设置页会显示同步状态。

不想用 iCloud：设置页关掉「iCloud 同步」开关即可，App 会退化成纯本地模式，其它功能不受影响。

## 目录结构

```
IceRecord/
├── App/               IceRecordApp（入口）、RootTabView（三个 Tab）
├── Models/            AssetItem / AssetSnapshot / AssetCategory
│                      StatsPeriod / TrendPoint / TrendAggregator
├── Database/          SQLiteDatabase（sqlite3 薄封装）、AppDatabase（建表 + CRUD + 同步落库）
├── Store/             AssetStore（@Observable，唯一数据源，写操作入口）
├── Sync/              SyncModels（记录模型）、SyncTransport（协议）
│                      CloudFileStore（文件存储抽象：iCloud 云盘 / 本地目录）
│                      SyncFileLayout（记录 → 文件的映射，按年分片）
│                      FileSyncTransport（读写 + 合并 + 指纹增量）
│                      SyncEngine（推/拉/合并）、SyncCoordinator（开关 + 生命周期 + 状态）
│                      SyncLog（os.Logger 日志）
├── Support/           DayKey（自然日口径）、AmountFormatter、AsyncTimeout
├── Views/             AssetsView、AssetEditorView、TrendView、SettingsView
└── Assets.xcassets/   AppIcon / AccentColor
IceRecordTests/        单元测试：数据库、Store 行为、日周月年归并、同步语义、文件分片与合并
IceRecordUITests/      端到端测试：首屏 → 新增条目 → 总资产重算 → 四种曲线 → 设置页
Tools/                 生成 App 图标、截图局部放大的脚本
```

## 数据存储

数据库文件位于 App 沙盒的
`Library/Application Support/IceRecord/IceRecord.sqlite`（界面里不展示，属于实现细节）。

```sql
CREATE TABLE asset_item (          -- 资产条目
    id TEXT PRIMARY KEY, name TEXT, amount REAL, category TEXT,
    note TEXT, sort_index INTEGER, created_at REAL, updated_at REAL,
    deleted_at REAL,               -- 墓碑；NULL 表示未删除
    sync_dirty INTEGER DEFAULT 1   -- 有未同步的改动
);

CREATE TABLE asset_snapshot (      -- 每个自然日一条总资产快照
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    day TEXT NOT NULL UNIQUE,      -- 'yyyy-MM-dd'，本地时区
    total_amount REAL NOT NULL,    -- 单位：万元
    item_count INTEGER, recorded_at REAL, updated_at REAL,
    deleted_at REAL, sync_dirty INTEGER DEFAULT 1
);

CREATE TABLE app_meta   (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE sync_state (key TEXT PRIMARY KEY, value TEXT);  -- 上次同步时间、文件指纹索引
```

`day` 上的 `UNIQUE` 约束 + `INSERT ... ON CONFLICT(day) DO UPDATE` 就是「同一自然日只保留最新值」的实现方式。

## iCloud 同步

用 **iCloud 云盘文件**（ubiquity container 的 `Documents/IceRecord/`），**按年分片**。

### 为什么是文件、为什么按年分

一开始用的是 `NSUbiquitousKeyValueStore`，也能跑通，但它的 1MB 是
**所有 key 加起来**的总配额——拆成多个 key 并不会变大，所以迟早会顶到上限。

iCloud 云盘文件没有这个总上限，而且分片之后：

- **单文件体积天然有上界**：一年最多 365 条快照，压缩后几 KB（实测 365 天 = 1 个约 2KB 的文件）；
- **平时只重写当年那个文件**，不用整坨重写（有测试守着：改 2026 年不会动 2025 年的文件）；
- 将来要按年裁剪、归档、或者按需下载都很直接。

### 文件布局

```
Documents/IceRecord/
├── items.json.deflate            ← 全部资产条目（数量少、经常改，一个文件足够）
├── snapshots-2025.json.deflate   ← 2025 年的每日快照
└── snapshots-2026.json.deflate   ← 2026 年的每日快照
```

每个文件都是 raw DEFLATE 压缩后的 `[SyncRecord]` JSON。
条目类型短码（`i` / `s`）、字段用数组带类型标记，尽量省体积：

```json
{"k":"s","u":811773838.7,"d":false,
 "n":"snapshot-2026-09-22",
 "f":{"totalAmount":[1,14.3],"itemCount":[2,3],"recordedAt":[3,1790006400]}}
```

> ⚠️ 是 **raw DEFLATE**，不是 gzip：Apple 的 `NSData.compressed(using: .zlib)`
> 输出的就是裸 deflate 流，没有 gzip / zlib 头。用 `gunzip` 解不开，
> Python 里要 `zlib.decompress(data, -15)`。

### 怎么同步

一轮同步是 **先推后拉再合并**：

1. 把 `sync_dirty = 1` 的记录按目标文件分组，逐文件读出远端内容、
   按 `updatedAt` 合并后写回。只有本地更新（或远端没有）才覆盖远端。
2. 再扫描同步目录，**指纹（文件大小 + 修改时间）没变的文件直接跳过**，不下载也不解码。
3. 逐条按 **last-writer-wins** 合并进本地 SQLite：
   - 远端 `updatedAt` 更新 → 覆盖本地；
   - 本地更新 → 保留本地，并重新标脏，等下一轮推上去；
   - 相同 → 视为已一致。

文件指纹索引存在 `sync_state` 里，跨启动复用；`push` 写完之后也会立刻更新内存里的索引，
所以紧接着的那次 `pull` 不会把自己刚写的文件再读一遍。

触发时机：App 启动、回到前台、本地改动后 3 秒（去抖）、设置页「立即同步」，
以及 iCloud 云盘的文件变化通知（别的设备改了数据）。

### 为什么用墓碑而不是物理删除

如果本地直接删行，离线设备再上线时无法得知「这里被删了」。
所以删除写成 `deleted = 1` + 新的 `updatedAt` 的普通记录，让 LWW 能正常裁决。

### 关键设计：不做自动播种

**App 启动时不会写任何示例数据。** iCloud 上的数据是异步回灌的
（系统可能在我们读完本地之后才把远端内容送过来），只要启动就自动播种，
重装 App 就一定会「本地新播的示例条目」和「同步回来的旧条目」重名重复
（之前实测：股票、流动资金各出现两份，总额从 11.80 变成 26.10）。

示例数据改成空状态里的 **「添加示例条目」** 按钮，只在列表为空时生效。

### 健壮性

- **iCloud 不可用**（没登录 / 云盘没开）：整轮跳过，**一个字都不动本地数据**，
  脏标记保留，等 iCloud 可用了整批补传。设置页如实说明，不会假装「已同步」。
- **单个文件损坏**：解不开就跳过它，不让一条坏数据把同步永久卡死；
  下一次推送会用本机数据把这个文件重建起来。
- **账号查询卡住**：8 秒超时；整轮同步 40 秒超时，界面不会卡在「正在同步…」。
- **单条记录失败**：不算致命错误，成功的照常标记已同步，失败的留在脏列表里下次重试。
- **主页面只在同步真的失败时**才提示，没登录 iCloud 这种情况不打扰。

### 日志

同步过程的每一步都写了 `os.Logger`，统一带 `[iCloud]` 前缀：

```
[iCloud] App 启动，同步位置：iCloud 云盘（/private/.../Documents/IceRecord）
[iCloud] iCloud 云盘：可用
[iCloud] 开始同步
[iCloud] 待上传 3 条本地改动
[iCloud] 推送：3 条 → items.json.deflate +3/3（325 字节），snapshots-2026.json.deflate +1/1（121 字节）
[iCloud] 拉取：扫描 2 个文件，下载 0 个（跳过未变化的 2 个），共 0 条记录
[iCloud] 同步完成：上传 3 条，拉取 0 条，本地更新 0 条
```

命令行实时看（`--level debug` 不能省，否则 info / debug 级别不显示）：

```bash
xcrun simctl spawn booted log stream --level debug \
  --predicate 'subsystem == "com.icerecord.app"'
```

设置页 →「iCloud 同步」→ **同步诊断** 里能看到位置、账号状态、
还有多少条没传上去、**云端每个文件的大小**、上次同步时间。


## 统计口径

| 粒度 | 归并方式 | 曲线取值 | 最多载入 | 一屏显示 |
| --- | --- | --- | --- | --- |
| 日 | 每个自然日 | 当天最后一次记录 | 730 天 | 60 个点 |
| 周 | 自然周（周一起） | 该周最后一次记录 | 260 周 | 60 个点 |
| 月 | 自然月 | 该月最后一次记录 | 120 月 | 60 个点 |
| 年 | 自然年 | 该年最后一次记录 | 50 年 | 60 个点 |

横轴**不显示日期**。那块标签区既占竖向高度，又逼着两端为「放得下标签」各让一段留白，
而它提供的信息（哪一天）长按气泡里本来就有。现在只保留等距的竖向网格线，
两端各留 1.5% 的时间余量，曲线几乎铺满卡片宽度。
区间信息改由图表下方一行文字给出（`10-03 – 11-01`，单位：万）。
复合柱状图**不适用**：每根柱子要能对上期数，日期照常显示。

点数超过 **60** 个时，图表下方出现一条滑条，用它切换要看的那一段（默认停在最近 60 个点）。
**曲线本身不响应拖动**：拖动手势留给长按选点，翻页只走滑条——两者抢同一个手势会互相打断。
滑条下方给出「显示」的这一段和「全部」的范围，**纵轴取值范围与区间统计也只按这一段算**，
否则早年 8 万的旧数据会把今天 15~20 万的曲线压成一条贴顶的线。
纵轴上下各留 18% 的余量（峰值/谷值不贴边），刻度用 1/2/5×10^k 的步长取在域内，等距且不重复。

图表卡片的**四角都是直角**：`insetGrouped` 的 section 会把每行内容裁成圆角，而纵轴数字正好长在左上、左下两处，
所以图表挂在 section 的 **header** 上（header 不受卡片裁切），并自己画一块四角直角的底（右侧若留圆角，一边方一边圆会显得歪）。
另外 Charts 不会把自己裁进 frame，面积填充会溢出到框外，必须显式 `.clipped()`。
卡片底色必须与图表等宽：`background` 要加在负 padding **之前**，否则底色按「没被撑开」的尺寸画，
曲线和纵轴数字会从卡片两侧漏到页面底色上。

纵轴刻度取「好看的步长」（1/2/5/10…）再取整，避免四舍五入把 20.4 和 20.6 都显示成两个「20」；
只有变化量小到零点几万时才保留一位小数。

## 分类走势

每日快照除了总额，还按 7 个资产类别各记一行（金额为 0 也记，某类清空后曲线才能落回 0），
保存在 `snapshot_category(day, category, amount)`。分类明细与总额**同一事务**写入、整体覆盖，
删除快照时一并清除；同步时内嵌进当天的快照记录一起走，不单独成记录。

分类明细只能从本版本上线当天开始积累，更早的日期只有总额，因此分类曲线 / 复合视图的横轴会比总资产短——
界面会写明起点，不做任何按比例倒推的补造。

复合模式的分组柱状图里，**柱高是各类别相对上一期的变化量**，柱色只标识类别身份（涨跌由零轴上下表达，
红绿语义留给下方列表）。桶数按绘图区宽度反算：柱子不许细过 5pt、桶下的日期标签也不许互相压住，
放不下就少画几期，而不是把整个周期压成一根线。

## 测试

```bash
xcodebuild test -project IceRecord.xcodeproj -scheme IceRecord \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.4'
```

当前 **78 个测试全绿**（75 单元 + 3 UI）。

单元测试覆盖：

- 建表 / 迁移、首次启动示例数据只写一次、增删改后当日快照被就地更新、历史日期不被今天的修改污染、排序持久化；
- 日/周/月/年四种归并结果；
- 横轴刻度的选取与文案（按时间等距、同月/同年合并、**按文字实际宽度收敛数量**、任意宽度下都不叠字）；
- **iCloud 同步语义**（用 `MockSyncTransport` 驱动 `SyncEngine`）：本地改动被推送并清脏、
  删除以墓碑推送、远端新记录插入、远端更新覆盖本地、本地更新不被旧数据覆盖、
  远端删除传播、快照按天合并、部分记录被拒时只留脏不卡住整轮、
  未登录 iCloud 时照常写入本机、推送失败时数据不动也不丢；
- **文件 transport 本身**（用本地临时目录当云盘）：**按年分片**、
  改一年不会重写别的年份、单年文件体积上界、编解码往返、坏文件按空处理、
  推送时的 LWW 合并、两台设备各写各的不会互相覆盖、
  以及**指纹增量**（没变的文件不重读、`push` 刚写的文件不被自己重读、新出现的文件能被发现）。

> **没有覆盖到的部分**：iCloud 云盘真正的跨设备同步（需要登录 iCloud 的真机，
> 而且容器要在你的账号下能建出来）。存储被隔离在 `CloudFileStore` 协议后面，
> `FileSyncTransport` 里只有编解码、分片、合并、指纹这几件事，都被本地目录实现完整覆盖了。
> 另外 Debug 下可以用 `--use-local-sync-directory` 把云盘换成本地目录，
> **在模拟器里跑完整的文件同步链路**（UI 测试就是这么跑的），实测写出：
> `items.json.deflate` 325 字节、`snapshots-2026.json.deflate` 121 字节。

UI 测试覆盖：首次启动 → 新增条目 → 总资产自动重算 → 日/周/月/年四种曲线 → 长按选中某一天 → 设置页同步状态。
`testSelectionGestureShowsCalloutWithoutCrashing` 会在选中状态下按住 8 秒，
方便用 `xcrun simctl io <device> screenshot` 在外部抓图核对气泡。

`Tools/crop_png.swift` 可以把截图局部放大，用来肉眼核对曲线和刻度是否对齐。

### 六个踩过的坑（不要再犯）

1. **不要给 Chart 用 `.chartPlotStyle { $0.padding(...) }` 来腾地方。**
   它只会下移**数据区**，Y 轴刻度和标签不跟着动，结果曲线整体偏移一个 padding 的高度——
   实测 19.91 万的点被画到了 16.7 万的位置。
   气泡的位置应该靠「挂在数据点上 + 按相对高度选朝上/朝下弹」来解决。
2. **气泡不要用 `.regularMaterial` 当背景。** 材质在深色背景 / 不同环境下会解析成深色，
   出现黑底黑字。固定用浅灰 `Color(white: 0.96)` + 黑色文字 + 描边。
3. **不要裸等云服务的回调。** CloudKit 的 `accountStatus()` 可能永远不返回，
   所有跨进程等待都要有超时，否则 UI 会永久停在「正在同步…」并且按钮变灰。
4. **不要在启动时自动写示例数据。** iCloud 数据是异步回灌的，自动播种必然和同步回来的旧数据重名重复。
   示例数据只在「列表为空」时由用户显式添加。
5. **不要给折线图的横轴加日期标签。** 早期版本为了「让范围一眼可读」塞了 5~6 个日期刻度，
   由此衍生出一串坑：`AxisValueLabel(anchor:)` 的对齐方式随 iOS 版本变（18/26 居中、27 左对齐，
   右端日期被裁成「11-0|」）；`centered: true` 又会让贴边的最后一个标签**整个不画**；
   两端为放标签留的白边吃掉了十几个点绘图区宽度。结论是把标签整个去掉，只留网格线，
   区间信息交给图表下方那行文字，具体日期交给长按气泡——一套 `TrendAxis` 的收敛逻辑随之删掉。
6. **`AxisMarks(values:)` 传自定义日期数组时，贴边的那个标签行为不可靠。**
   要么不画、要么被裁，而且不同 SDK 表现还不一样。需要日期文字时优先用
   `preset: .aligned`（首尾自动向内对齐），并给两端留够整字宽。

## 调试开关

两个都只在 DEBUG 编译里生效，在 Xcode 的 Scheme → Run → Arguments 里加：

| 参数 | 作用 |
| --- | --- |
| `--seed-demo-history` | 生成约 200 天的演示曲线，用来看图表效果。这些快照写入时带 `sync_dirty = 0`，**不会被推到 iCloud**，不污染真实数据。 |
| `--use-local-sync-directory` | 把「云端」换成本机 `Library/Application Support/DebugSyncDirectory`，用来在没有 iCloud 的模拟器里跑完整的文件同步链路（UI 测试用的就是这个）。 |
