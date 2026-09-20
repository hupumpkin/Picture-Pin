# 送审清单 · 批次 C1 最小采集闭环（CC → Codex）

> 送审日期：2026-09-17
> 送审人：CC（Claude）
> 对照文档：`pin-macos/BATCH_C_TASK.md`、`PIN_NATIVE_CANVAS_KERNEL.md`、`pin-macos/HANDOFF.md`、`VERSION_HISTORY.md`
> 工作区：`/Users/huwenhao12/Documents/截图分析管理工具-native`
> 分支：`native/pin-macOS/canvas-kernel-a`
> 基线提交：`d7680f5`（`PIN-NATIVE: Add canvas kernel and B2 review`；本轮**未提交**，路线图 §6）
> 交付标识：`BASELINE-A.sha256`（重新生成，**51 → 70 个文件**；文件集合与哈希 `--check` 通过）
> 自检：**380 → 626 项**，626/626 通过（Debug 与 Release 各跑一遍）
> 送审结论：**未验证项与已知边界见 §6、§7，请优先质疑那两节。**

## 1. 本清单的范围

本清单覆盖**批次 C1**：第一批（§7 第 10 条三项缺陷）+ §3.1–§3.7，即「一条采集
通道走到底」——文件选择器导入 → 入库 → 上画布 → 重启恢复 → 素材面板真数据。
C2 的两条通道（拖入 / 粘贴）与损坏库完整形态**不在**本清单。

| # | 事项 | 状态 | 证据 |
| --- | --- | --- | --- |
| 1 | 第一批三项缺陷（重试 / 手感刷新 / 驻留账本） | 已修 + 注入 | `BATCH_C_TASK.md` §7 第 10 条执行记录（380 → 428） |
| 2 | §3.1 数据层（GRDB + 素材/画布/元素/快照） | 已做 + 断言 | 「持久化」组（428 → 475） |
| 3 | §3.2 真解码（`FileImageProvider` 双协议） | 已做 + 断言 | 「真解码」组（475 → 498） |
| 4 | §3.3 采集通道（`ImportCoordinator` + §3.9 政策） | 已做 + 断言 | 「采集通道」组（498 → 551） |
| 5 | §3.4 面板接真（`ScreenshotMaterialProvider` + 闸门） | 已做 + 断言 | 「素材面板接真」组（551 → 581） |
| 6 | §3.5 恢复（文件丢失不静默删元素） | 已做 + 断言 | 「恢复：素材文件丢了」组（581 → 587） |
| 7 | §3.6 基础 UI（导入按钮 + 状态胶囊 + 语义色） | 已做 + 断言 | 「导入结果摘要」组（587 → 593） |
| 8 | §3.7 调试入口（`--import` / `--library-report`） | 已做 + 断言 | 「调试入口」组（593 → 616） |
| 9 | 验收反馈修复：透明 PNG 灰底（626 里 +10 条） | 已修 + 注入 | 「真解码」组透明通道一节 + `BATCH_C_TASK.md` 验收反馈记录 |

**本轮的门槛是 380**：那 380 条**断言本身一条没删**（其中 1 条补充了断言），
现在仍然全绿（626 = 381 + 245）。
本轮动的正是它们覆盖的代码路径（渲染器、缓存、画布宿主、素材面板），所以那 380 条
是**重跑过**的，不是"没碰过所以自然还是绿的"。

## 2. 改动文件清单

以 `d7680f5` 为界：**新增 12 处（23 个文件，另加本送审清单与 `CODEX_HANDOFF_C1.md`
两份交接文档自己）、修改 17 处（22 个文件）**。行号是写入时的，可能漂移。
其中 `BATCH_C_TASK.md` 与 `TestAssets/`（6 个文件）在上一版清单（51 文件）里已登记，
所以清单差额是 70 − 51 = 19（多出的两份是本送审清单与实测交接文档自己）；下面的「新增」是**对 git 基线**的口径。

### 2.1 新增（13 处）

| 文件 | 做什么 | 为什么单独成文件 |
| --- | --- | --- |
| `Persistence/Database.swift` 等 5 个（`Schema` / `AssetStore` / `SceneStore` / `LibrarySnapshot`） | 数据层唯一入口：GRDB 连接、迁移、素材落盘、画布读写、恢复快照 | §3.1 表：GRDB 只允许出现在 `Persistence/` 一处 |
| `Assets/FileImageProvider.swift` | 真解码：`ImageProvider` + `ImageFileProbing` 双协议 | 渲染与导入探针共用同一实现，路径不分叉 |
| `Assets/ImageRetryPolicy.swift` | 失败退避重试（0.5/1/2 秒，共 3 次） | 第一批 ① 的政策；`.missing` 不自动重试 |
| `Assets/ImageResidency.swift` | 图层持有像素的账本（第一批 ③） | 缓存淘汰顺序要读它，与 `ImageCache` 分开 |
| `Import/ImportCoordinator.swift` 等 3 个（`ImportPolicy` / `ImportFeedback`） | 采集通道唯一入口 + 尺寸政策 + 界面摘要 | 三条通道共用一条流水线（C2 接拖入/粘贴时只加采集动作） |
| `Materials/ScreenshotMaterialProvider.swift` | 截图源接真库（条目 + 缩略图 + 闸门） | 与占位来源并列的提供者实现 |
| `UI/MaterialItemRowView.swift` | 素材条目行（只吃数据、不持有 store） | §3.6 留白规则：行视图可单独替换 |
| `UI/ImportStatusToast.swift` | 导入进度与结果胶囊 | 只吃 `ImportFeedback`，不读 outcomes 字典 |
| `Tools/HeadlessImport.swift` / `Tools/LibraryReport.swift` | `--import` / `--library-report` 调试入口 | 与 `--snapshot` / `--selftest` 同构，先于 App 退出 |
| `BATCH_C_TASK.md` | 批次 C 开工任务单 + 各节执行记录 | 审核对照的原始依据 |
| `Package.resolved` | GRDB 锁版本 | §7 第 1 条：锁定依赖 |
| `TestAssets/`（5 个文件） | 产品负责人放入的 4 个原始素材 + README | §7 第 11 条：改名原因与哈希核对在 README 里 |

### 2.2 修改（20）

| 文件 | 改了什么 | 为什么 |
| --- | --- | --- |
| `Canvas/LayerRenderer.swift` | 第一批 ①②：`displayed` 只在 `.image` 分支写 + `requested` 记账；`setMotionConfiguration` 触发重扫 | 瞬时失败后不再"永远不重试" |
| `Assets/ImageCache.swift` / `ImageProvider.swift` / `SyntheticImageProvider.swift` | 驻留账本接口、解码上限夹子、失败文案统一常量 | 第一批 ③ + §3.2 |
| `App/WorkspaceModel.swift` | `prepareStorage` / `restore` / `importFiles` / 素材来源刷新 | 库接线与导入入口 |
| `App/PinNativeApp.swift` | 注册 `--import` / `--library-report` | §3.7 |
| `App/AppEnvironment.swift` | `--data-dir` 覆盖解析 | 调试入口默认打真实 profile，自动化打临时目录 |
| `Materials/MaterialProvider.swift` / `MaterialSource.swift` | 协议级 `thumbnail` + `AssetStoreLookup` 迟到接线 | §3.4 |
| `UI/CanvasToolbar.swift` | 导入按钮（最左 + 分隔线） | §3.6 |
| `UI/WorkspaceView.swift` | `.fileImporter` + 状态胶囊浮层 + 语义色 | §3.6 |
| `UI/MaterialPanel.swift` | 真实条目 / 失败态 / `contentShape` 命中契约 | §3.4 |
| `Design/DesignTokens.swift` | `Surface.success` / `warning` 语义色 | 两处裸 `.orange` 收编 |
| `Tools/SelfTest.swift` | 8 个新自检组 + 若干工具 | 236 条新断言 |
| `Tools/SnapshotHarness.swift` | 快照模型换真库 | C1 起画布像素来自素材库 |
| `Tools/DevelopmentCommands.swift` | 演示素材走真导入流水线 | 与 §3.3 同一条路 |
| `Canvas/Board.swift` / `CanvasHostView.swift` | 库接线与元素引用 | 恢复与导入路径 |
| `Package.swift` | 加 GRDB 依赖 | §7 第 1 条 |
| `HANDOFF.md`（`pin-macos/`）与 `VERSION_HISTORY.md`（工作区根） | 批次 C1 交接一节 + 运行命令块；版本日志 C1 条目 | §3.8 交付物 |
| `BASELINE-A.sha256` | 重新生成 | 交付标识 |

## 3. 断言账本（626 条）

| 组 | 条数 | 钉住什么 |
| --- | --- | --- |
| 失败重试 / 驻留账本 / 视口外不留全尺寸（第一批） | +49 | 瞬时失败自动退避重试且重试后能显示；驻留字节 = 缓存 ∪ 图层；离屏只留小档；**成功之后底色整块撤掉**（原为"换回占位色"，透明修复时改口） |
| 持久化（§3.1） | +47 | WAL、v1 结构、失败导入不留半成品、字节与 SHA-256 一致、画布/元素/顺序往返、调度器合并、外键 RESTRICT + CASCADE |
| 真解码（§3.2） | +29 | probe 摆正、缩略图目标尺寸、缓存档位记账、inFlight 合并、三态、非主线程解码；**透明通道**：真写带 alpha 的 PNG、逐像素读回透明角落、缩略图路径不压平、渲染器两条路径（真解码 / 缓存种子）都不留底色 |
| 采集通道（§3.3） | +53 | 单张居中、网格排布、原比例、超限拒绝在复制前、逐文件失败不连坐、定位表立刻装好 |
| 面板接真（§3.4） | +30 | 状态机 idle→loaded、按时间倒序、条目字段、失败文案、缩略图 32×32、共享缓存、闸门峰值 ≤ 4、模型集成 |
| 恢复（§3.5） | +6 | 文件丢了元素仍在、还引用原素材、解码落 `.missing` |
| 导入摘要（§3.6） | +6 | 计数、第一条失败按用户顺序、兜底计数 |
| 调试入口（§3.7） | +23 | 参数解析 5 条、报告每个段落都在 13 条、真库对照 4 条 |

## 4. 注入实测汇总

协议：备份 → 注入缺陷 → 记录红 → `cmp` 字节级还原 → 零标记 → 全绿。C1 共 **30 次
注入**（第一批 3 + §3.1 六种 + §3.2 七种 + §3.3 九种 + §3.4 五种 + §3.6 三种 +
§3.7 四种 + 透明修复两种），红项与预期逐条对过，全部落在对应断言组内；§3.5
守卫式断言无缺陷形态可注入（如实记录）。逐次的红数与缺陷形态见
`BATCH_C_TASK.md` 各节执行记录，摘要：

| 节 | 注入数 | 典型红法 |
| --- | --- | --- |
| 第一批 | 3 | 重试守卫 7 红；驻留账本 2/4/1 红 |
| §3.1 | 6 | 顺序收尾 1 红；失败清理 1 红；合并失效 1 红；库加相机列 1 红；删元素连带删素材 1 红；journal 切换无法干净注入（如实记录） |
| §3.2 | 7 | 方向不调换 6 红；删 transform 4 红；文案 1 红；missing 区分 1 红；取消判据 2 红；inFlight 1 红；主线程解码 1 红 |
| §3.3 | 9 | 政策拿掉 5 红；定位表拿掉 1 红；网格锚点/间距/比例 4+3+2+1 红；解码上限 3 红；文案 2+1 红 |
| §3.4 | 5 | 吞错 1 红；lookup 空 2 红；ID 不稳定 2 红；闸门撤限 1 红（峰值 10）；绕过闸门 1 红（峰值 10） |
| §3.6 | 3 | 首败顺序倒置 2 红；兜底计数漏掉 1 红；计数对调 4 红 |
| §3.7 | 4 | -wal/-shm 漏行 1 红；素材清单整个没了 4 红；版本写死 2 红；--data-dir 不消费 2 红 |
| 透明修复 | 2 | `finish` 种回灰底 3 红（种子路径那条正确保持绿）；种子路径种回灰底 1 红 |

**注入本身抓到过两个真缺陷**：§3.1 的 `user_version` 从未写入（库版本恒 0）；§3.6
第一版摘要按 Swift Dictionary 迭代序取"第一条失败"（迭代序随进程哈希种子变，
自检两条断言随机红）——修法是签名加 `orderedBy`。两者都进了上表之外的执行记录。
**真机验收抓到过第三个**：透明 PNG 显示灰底（元素图层把占位底色一直留着，
透明区域透出它）——也是执行记录里的一节，修复过程见上表"透明修复"两行。

## 5. 七个判断（请优先复核）

1. **出口条件是否真的成立**：`--import TestAssets/ 四张 → 打开 App → 画布四张图
   → 退出重启 → 还在`。我已用 `--import` + `--library-report` 在临时目录走通
   （§7 证据），但**重启恢复 + 真窗口观感**需要你在真机走一遍。
2. **§3.3 的"失败不连坐"与"不留半成品"**：一批里坏一张，另外几张照常进来；
   被拒文件一个字节都不落盘。断言有，注入有，请你在文件系统上再点一次数。
3. **§3.4 的面板接真**：条目按 `added_at DESC`、缩略图 32pt 且共享缓存、
   并发闸门 4。这几条都有断言；**几百条素材时滚动流不流畅没有实测**（§7）。
4. **§3.6 留白规则是否守住**：色值/字号/圆角/间距只从 `DesignTokens` 取（本轮
   新增 `success`/`warning` 两个语义 token）、文案集中 `Copy`、无写死尺寸、
   `// 精校留白` 只有一处（胶囊停留时长与消失方式）。请按 §3.6 清单逐条挑。
5. **§3.7 入口的可用性**：`--import` 默认打真实 profile、`--data-dir` 打临时目录；
   退出码全成 0 / 任一被拒 1。请实际跑一遍（含一个不存在的文件）。
6. **数据边界**：原生版从全新空库开始（§6）——请确认代码里没有任何读、迁移、
   删除旧 DesignPeek / Pin Web / CC Web 数据的路径。
7. **透明修复的两条路径**：真图到位后图层必须**一点底色都不留**（`finish` 与
   缓存种子各一条，断言与注入都只有一条路各打一处）。判据是"有没有底色"，
   不是"是什么颜色"——颜色的取值以后可以改。请确认没有第三种铺像素的路径
   被漏掉。

## 6. 未验证清单（按 §9 口径，不用"已完成"）

- **真窗口观感**：Liquid Glass 材质、导入按钮手感、状态胶囊的 4 秒自动消失——
  快照离屏渲染复现不了材质，胶囊要触发导入才出现，八张快照里都没有它。
- **多文件导入的真实面板刷新**：断言覆盖模型层（导入后面板条目跟着走），
  真窗口一次选几十张的观感未实测。
- **几百条素材的滚动性能**：闸门把并发压在 4，但整段体验没有数字。
- **大库首次恢复时间**：没有基线（§2.4 的启动目标是空画布口径）。
- **屏幕倍率实机行为、鼠标滚轮系数**（B2 遗留，无硬件）。
- **HEIC 实机收数、超长图样本、损坏库完整形态**：属 C2。

## 7. 证据

- 自检：Debug 与 Release 各一遍 **626/626**。
- 快照：八张已重建（`build/snapshots/`），含一张有内容的与一张不套相机的越界对照。
- 性能复跑（release，`build/perf-report-c1.txt`）：空画布启动 **40.9 ms**（目标 800）；
  1000 元素平移主线程 P95 **0.158 ms**；图层提交 P95 < 0.02 ms——与 B2 报告同量级，
  无回归迹象。完整输出在 `build/perf-report-c1.txt`（`build/` 不进清单，原始命令
  `swift run -c release PinNative --perf-report` 可复现）。
- 采集链路实测（临时目录，跑完即删）：四张 TestAsset 一次导入，**4/4 成功**，
  写调度器 收活 5 / 提交 2 / 重排队 0；`--library-report` 同目录打出 4 表结构、
  WAL、画布 1 块、元素 4 个、素材 4 条（逐条含像素尺寸与字节数）。不存在的文件
  → 「读不了这个文件」exit 1。
- 交付标识：`BASELINE-A.sha256`（70 个文件），`scripts/manifest.sh --check` 通过。
- 实测交接：`pin-macos/CODEX_HANDOFF_C1.md`（怎么跑、要亲手验什么、接口接手面）。

## 8. 本轮不做（§5 与 Codex 的边界 + BATCH_C_TASK §8）

元素拖拽/缩放、多选框选、撤销重做（Codex）；Finder 拖入、粘贴、损坏库完整形态、
HEIC 实机收数（C2）；素材删除与重命名、AI/字体/文字/OCR、网页采集、签名与公证。
手动"点一下重新加载"是产品负责人 §7 第 9 条定的两半：自动退避重试 + 元素上可点
的入口。C1 交了前半（在跑）与渲染器 API（`retryImage` / `retryAllFailedImages`，
经 `CanvasHostView` 暴露）；**元素上的入口还没有 UI**，与拖拽/选择一样归 Codex。
