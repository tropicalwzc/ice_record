# Tasks

## 1. 数据库与迁移

- [x] 1.1 在 `AppDatabase` 增加 `schemaV3`：`snapshot_category(day, category, amount, PRIMARY KEY(day, category))`，`user_version` 2 → 3，然后验证「新建库直接是 v3」与「从 v2 旧库升级后表存在且老快照不丢」两个用例通过（`SnapshotCategoryTests`）
- [x] 1.2 实现按日期集合一次性读取分类行并组装成 `[dayKey: [AssetCategory: Double]]`，然后验证：插入 2 天 × 7 类共 14 行后分组正确、只发出一次查询（`SnapshotCategoryTests`）
- [x] 1.3 让 `deleteSnapshot` / `deleteAllSnapshots` 级联删除对应日期的分类行，然后验证墓碑后分类行数为 0（单元测试）

## 2. 写入路径

- [x] 2.1 把 `upsertSnapshot` 扩展为同一事务内「写快照 + 按 day 删除旧分类行 + 插入全部 7 行」，然后验证：连续写两次不同值后该日仍为 7 行、值为最新，且 `sum(category) == total`（`SnapshotCategoryTests`）
- [x] 2.2 `AssetStore.persistSnapshotForToday` 按 `items` 分组求和生成 7 类全额拆分（含 0），然后验证：新增一条 `股票 2.50` 万后当日 `stock = 2.50`、其余类别为 `0`（`AssetStoreTests`）
- [x] 2.3 `AssetSnapshot` 增加 `categories: [AssetCategory: Double]?`（`nil` 表示该日无分类明细，与「全 0」区分），然后验证：旧数据读出为 `nil`、新写入读出为 7 项（`SnapshotCategoryTests`）

## 3. 同步

- [x] 3.1 `SyncRecord.snapshot` 增加 `categories` 字段并实现编解码，然后验证：解码缺少该字段的旧记录不抛错且取值为 `nil`（`SyncEngineTests` 构造旧记录并走一遍 JSON 编解码）
- [x] 3.2 `fetchDirtyRecords` 组装分类、`applyRemoteSnapshot` 解包并写入分类表，然后验证：远端带分类的快照合并后本地分类与总额一致，且再次推送时分类随记录一起走（`SyncEngineTests`）
- [x] 3.3 处理「远端分类合计与总额不自洽」的情况：不静默接受，记 `applyFailureSummary` 并保持原值，然后验证该异常用例被测试覆盖（坏记录被跳过、好记录照常合并、整轮同步不中断）

## 4. 归并模型

- [x] 4.1 新增 `CategoryTrendPoint` 与 `CategoryTrendAggregator`：桶内取该类最后一条记录，`delta` 与**该类上一个存在的桶**相减，首桶为 `nil`（不是 `0`），然后验证：跨周归并、首桶 `nil`、某桶该类无记录时不产生多余点（`TrendAggregatorTests` 新增 4 条用例）
- [x] 4.2 新增源文件后执行 `xcodegen generate`，然后验证 `xcodebuild build` 成功且 `CategoryTrend.swift` 被加入工程
- [x] 4.3 在变更目录写 `verification.md`，明确记录本机无法自动验证的部分（真机 iCloud 往返后的分类合并、多设备并发写入的最终一致性），然后验证文件存在且列出至少两条

## 5. 横轴与绘图区（可独立验收）

- [x] 5.1 ~~把 `TrendAxis.label` 改为数字族~~ → **需求变更：横轴不再显示日期**，改为删除 `TrendAxis` 与其 8 条测试、折线横轴只保留网格线、区间信息移到图表下方说明文字；验证：截图确认横轴无任何日期文字且下方显示 `10-03 – 11-01`，`openspec validate --strict` 通过
- [x] 5.2 ~~刻度上限由 5 提到 6~~ → 标签取消后上限无意义；改为把 `plotWidth` 的估算常量由 64 降到 52（仅用于柱状图桶数与柱宽估算），并给折线两端只留 1.5% 时间余量，验证：截图里首尾数据点贴近绘图区边缘
- [x] 5.3 放大绘图区：图表行 `.listRowInsets(EdgeInsets())`、纵轴改为「好看步长」的整数刻度、图表高度 240 → 300，然后验证：截图里图表左右贴合卡片内容区、纵轴为 `18.5 / 19 / 19.5 / 20 / 20.5` 这类不重复刻度、高度 300pt
- [x] 5.4 复查没有引入 `chartPlotStyle(padding:)`，然后验证：全仓库只有一处注释提到它、没有调用；同一次截图里数据点与纵轴刻度仍然对齐

## 6. 视图切换与分类曲线

- [x] 6.1 `TrendView` 增加 `TrendScope`（`total` / `composite` / `category(AssetCategory)`）与 Section header 右侧的 `Menu`，然后验证：三个 scope 分别以默认值启动并截图，标题、配色、数据都随之切换（菜单本身的点击交互需在有图形界面的模拟器上确认）
- [x] 6.2 分类曲线：只画该类别、纵轴范围按该类自身计算、区间统计与长按气泡跟随当前类别，然后验证：截图里「股票曲线」纵轴为 11.5–12.5、突出显示为类别红、区间统计显示股票自身的 11.53 / -0.34
- [x] 6.3 分类视图的横轴范围取该序列自身首尾点，然后验证：`CategoryTrendAggregator.series` 只输出有明细的桶（单测覆盖），切换视图不会补出空白段
- [x] 6.4 空状态与起点文案：`AssetStore` 暴露 `categoryTrackingStartDay`，无分类数据时显示「分类明细自 yyyy-MM-dd 起记录」，然后验证：`AssetStoreTests` 断言「只有总额的老快照不算起点、第一条带明细的才算」

## 7. 复合柱状图与幅度列表

- [x] 7.1 实现桶数与类别数按宽度反算（每根柱 ≥ 5pt、桶间 8pt、下限 5 桶；不足时先减桶再取 Top6 + 其他），另加「桶下日期标签不得互相压住」的第二个天花板，然后验证：截图里 4 个类别时收敛到 8 个桶、日期标签完整不叠；类别降到 4 个时不再把桶数放宽到 11
- [x] 7.2 分组柱状图：柱高为 `delta`、柱色为类别色、首个桶无柱、`delta == 0` 画 0 高柱，然后验证：截图里柱子按类别分组、涨在零轴上方跌在下方、图例只列出真正有金额的 4 个类别；单测断言首桶 `delta == nil`
- [x] 7.3 幅度列表：按 |变化| 降序、末行合计、涨红跌绿持平灰、周期口径与图一致，然后验证：截图里列表显示 `股票 11.53 / +0.15 万（+1.32%）` 并带期初值；`deltaSums` 与柱子的累计口径一致
- [x] 7.4 footer 标注复合视图实际展示的期数，然后验证：截图 footer 显示「共 8 期」，与横轴 8 个桶逐个对应

## 8. 演示数据与集成

- [x] 8.1 `seedDemoHistoryIfNeeded` 为每条演示快照生成 7 类拆分，然后验证：`--seed-demo-history` 启动后复合视图有 8 组柱、分类视图有曲线（截图确认）
- [x] 8.2 跑完整测试：`xcodebuild test`（88 单元 + 3 UI），全部通过
- [x] 8.3 更新 `README.md` 中走势页的说明（视图切换、复合柱状图口径为变化量、横轴数字族与整字宽留白、分类明细起点），然后验证文档描述与截图里的实际行为一致

## 9. 长历史的滑动窗口（后续追加）

- [x] 9.1 把「载入上限」与「一屏上限」拆开：`StatsPeriod.maxPoints` 提到日 730 / 周 260 / 月 120 / 年 50，新增 `visiblePointLimit = 90`，然后验证：45 天数据不再被截断、超过载入上限才截断（`TrendAggregatorTests` 两条用例）
- [x] 9.2 新增 `TrendWindow`（纯值类型）负责窗口计算，然后验证：60 点无滑条/61 点有滑条、默认偏移=总点数-60、越界夹紧、短序列与空序列边界（6 条用例）
- [x] 9.3 视图接入区间控制：~~`chartScrollableAxes` 直接拖曲线~~ → **改动：拖曲线与长按选点抢手势**，改为图表下方一条独立 `Slider` 控制偏移，切粒度/切视图时重置到最近一段；验证：截图里 201 个点默认停在最近 60 个、滑条与「更早 / 共 201 个点，每屏 60 个 / 更新」文案正常
- [x] 9.4 纵轴范围与区间统计改为只按当前这一段计算，然后验证：截图里纵轴为 18/19/20 且峰值 20.54 落在线内，而不是被早年 8 万压到 10~20
- [x] 9.5 纵轴刻度算法：1/2/5×10^k 步长 + 只取域内刻度，域本身保留 18% 上下余量；验证：刻度等距（18/19/20）、峰值与谷值都不贴边。过程中修掉两处自造的退步——吸附到刻度切掉了峰值、`floor` 外扩让「刻度数量」虚高导致永远不细化
- [x] 9.10 把右侧两处圆角也去掉，卡片四角全为直角（`UnevenRoundedRectangle` → `Rectangle`），然后验证：像素扫描显示卡片的每一行都横跨 20…420pt（不再有角落收窄），与「区间统计」对齐
- [x] 9.9 修「曲线越出卡片右侧」：把 `.background` 移到负 padding **之前**（负 padding 只撑大内容，不撑大底色），并把左右外扩量从 10 改成实测的 20，然后验证：像素扫描显示卡片横跨 20…420pt 与「区间统计」严格对齐，纵轴数字与面积填充全部落在卡片内（此前分别越出 7pt / 5pt）
- [x] 9.8 把图表卡片左侧两角做成直角：图表从 section body 挪到 **header**（body 的行内容躲不开圆角裁切，`listRowBackground` 换形状与行内自绘背景都被切回圆角），自绘「左直角 + 右圆角」底，并用负 padding 补回 header 多出的约 10pt 内边距；同时给图表加 `.clipped()`（Charts 的面积填充会溢出 frame，以前被 List 的裁切盖住了）。验证：截图里左角为直角、右角圆角、与「区间统计」卡片左右对齐、蓝色填充不再压到滑条与页脚
- [x] 9.7 处理卡片圆角裁切：图表行上下各留 12pt（≥ 圆角半径），并让刻度兜底不再返回绘图区端点，然后验证：截图放大后最上一个纵轴数字（`20`）完整可见、距卡片上边缘仍有明显空白；规格新增「图表内容不得被卡片圆角裁切」
- [x] 9.6 规格改写「曲线点数量受控」，然后验证：`openspec validate --strict` 通过，且保留了旧场景名「按日粒度的上限」


## Workflow follow-up

- 评审通过后归档该变更，让 delta 合并进 `asset-tracking` 与 `asset-trend-chart` 主规格。
- 归档后检查 `openspec/specs/asset-trend-chart/spec.md` 的 Purpose 是否仍能覆盖新增的分类视图，必要时补齐。
