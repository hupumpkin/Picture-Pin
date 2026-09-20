# 交接文档 · 批次 C1 实测（CC → Codex）

> 交接日期：2026-09-18
> 交接人：CC（Claude）  →  接手人：Codex
> 基线提交：`d7680f5`（本轮**未提交**，路线图 §6）
> 对照文档：`BATCH_C_TASK.md`（任务单与执行记录）、`CODEX_REVIEW_REQUEST_C1.md`
> （送审清单：断言账本/注入汇总/六个判断/未验证清单）
> 交付标识：`BASELINE-A.sha256`，`scripts/manifest.sh --check` 通过

C1 交了「文件选择器导入 → 库 → 画布 → 重启恢复」一条通道 + 基础 UI（626 自检、
30 次注入实测、8 张快照）。**这份文档只讲一件事：哪些要你亲手在真机验证，
以及你接下来要接手的东西在哪。** 代码走读与断言复核按送审清单那份来。

---

## 1. 先跑起来（三条路，别走错数据目录）

| 方式 | 命令 | 落在哪 |
| --- | --- | --- |
| 双击包（推荐） | `./scripts/build-app.sh debug codex` → 双击 `build/Pin-codex.app` | `~/Library/Application Support/Pin/dev-codex/` |
| 终端 | `PIN_DEV_PROFILE=codex swift run PinNative` | 同上 |
| ⚠️ 裸终端 | `swift run PinNative`（不带环境变量） | **`dev-cc/`——CC 的目录，别在里面导图** |

- 正式包 `Pin.app` 落 `~/Library/Application Support/Pin/`（产品负责人的正式数据），
  实测一律不用它。
- `--import` / `--library-report` **默认打启动 profile 的真实目录**；自动化与试验
  一律加 `--data-dir /tmp/<随便>`。自检（`--selftest`）自己在临时目录跑，不碰真实库。
- 首次构建需要联网一次拉 GRDB（本工作区已缓存，无需重复）。
- 素材文件在库里的位置：`<数据目录>/assets/<id 前两位>/<uuid>.<扩展名>`。

## 2. 要你亲手实测的（A 最关键）

### A. 采集链路端到端（C1 出口条件本体）

1. 双击 Pin-codex.app，点工具栏**最左**的导入按钮，选 `TestAssets/` 四张 →
   期望：状态胶囊「正在导入 4 张…」→「导入 4 张」（4 秒自动消失）；4 张进画布
   （网格排布）；素材面板出现 4 条真实条目（时间倒序、32pt 缩略图）。
2. ⌘Q 退出重开 → 4 张仍在画布、面板 4 条、元素顺序一致。
3. 同一批再导一次 → 面板变 8 条。**重复导入不合并**是产品负责人定的口径
   （§7 第 4 条），不是 bug。

### B. 失败路径（请在文件系统上点一次数）

4. 混批不连坐：造一个坏文件（`head -c 1000 TestAssets/pin-macos-test-01-*.png > /tmp/坏.png`），
   和 3 张好图一起导入 → 好的 3 张照常进画布与面板；坏的 1 张被拒，文案是
   「读不了这个文件：…」一类。`assets/` 下**没有**坏文件的半成品（零字节落盘）。
5. 删原图：在 Finder 里删掉 `dev-codex/assets/` 下任意一张原图 → 重开 App →
   那个元素**还在**、显示不出来（占位），**不被静默删除**；面板对应条目回退成图标占位，
   行不消失。
6. 超限拒绝：正对 §3.9 第 2 条，`ImportPolicy` 里最长边 > 40,000 或总像素 > 2 亿
   的文件会被拒（提示「这张图太大」），且复制前就判——文件系统上零残留。
   （没有现成的超限样本，属可选项；断言已覆盖，真机验证是加分项。）
7. CLI 退出码复核：
   ```
   swift run PinNative --import /tmp/坏.png --data-dir /tmp/验收库; echo $?   # 1
   swift run PinNative --import TestAssets/四张 --data-dir /tmp/验收库; echo $?  # 0
   ```
   同一目录再跑 `--library-report --data-dir /tmp/验收库`：段落齐全（结构/文件/内容）、
   journal 是 WAL、素材计数与逐条清单对得上。

### C. 性能与内存收数（正对 C2 §2.4 复测，先随手记数字）

8. 造一个几百条的大库（导入=同时上画布，所以画布上也会有对应元素——顺带就是
   大库恢复的压测）：
   ```
   cd pin-macos
   PIN_DEV_PROFILE=codex swift run -q PinNative --import \
     $(printf 'TestAssets/pin-macos-test-01-screenshot-1320x2868.png %.0s' {1..300})
   ```
   然后打开 Pin-codex.app：面板从头滚到底是否流畅、有无明显掉帧（有 Instruments 更好）。
9. 大库首次恢复时间：同一个库，从启动到画布可交互，秒表记个数（C1 没有基线，
   这是给 C2 留的起点）。
10. 内存政策（§3.9 第 1 条）：导入若干张大图，把其中几张滚出视口再拖回来——
    应看到「先糊一下再清晰」（产品负责人已知并接受的代价）；活动监视器里内存在
    看完一圈后的回落情况，记个数给 C2。

### D. 留白区与你的接手面（§3.6）

- **唯一的 `// 精校留白：`** 在 `UI/ImportStatusToast.swift`：胶囊停留时长（现 4 秒）
  与消失方式（现直接消失）——这是你的，按面板整体节奏调。
- 规则复述（改得动，不是重写）：颜色/字号/圆角/间距只从 `Design/DesignTokens.swift`
  取；文案集中在各视图顶部 `private enum Copy`；`XxxRowView` 只吃数据可整行替换；
  不写死尺寸；不引入自定义绘制。

**C1 交到你手上的接口**（§5 边界内你要用的）：

| 接口 | 位置 | 你接下来怎么用 |
| --- | --- | --- |
| `retryImage(for:)` / `retryAllFailedImages() -> Int` | `Canvas/LayerRenderer.swift`，经 `CanvasHostView` 暴露 | 元素上"重新加载"入口（§7 第 9 条的后半，UI 还没有，归你） |
| 自动重试在跑 | `Assets/ImageRetryPolicy.swift` | 0.5/1/2 秒共 3 次；`.missing` **不**自动重试，只走手动 |
| `ImportFeedback`（`.importing(total:)` / `.finished(imported:rejected:firstFailure:)`） | `Import/ImportFeedback.swift` | 胶囊重做时直接吃这个；首败按用户选文件顺序，别退回字典序 |
| `CanvasToolbar(onImport:isImportEnabled:)` | `UI/CanvasToolbar.swift` | 导入按钮最左 + 分隔线；`isImporting` 时置灰 |
| `MaterialItemRowView` / `MaterialPanel` 命中契约 | `UI/` | 行可整行替换；玻璃背景命中透明 + `.contentShape` 别改回去（否则空白处会穿透成平移画布） |
| `ThumbnailGate`（并发 4，取消安全） | `Materials/` | 面板缩略图不要绕过它直接解码 |
| `ImportCoordinator` | `Import/ImportCoordinator.swift` | C2 的拖入/粘贴只加采集动作，别再开一条流水线 |

### E. 数据隔离抽查（路线图 §6）

- 三个目录互不污染：`Pin/`（正式）、`Pin/dev-cc/`、`Pin/dev-codex/`。
- 代码里**没有任何**读、迁移、删除旧 DesignPeek / Pin Web / CC Web 数据的路径——
  抽查 `Persistence/` 与 `App/AppEnvironment.swift`。

## 3. CC 这边已验过、你不必重跑

626 自检（Debug + Release，含基线 381 条回归）、30 次注入实测（红数逐条对过）、
CLI 端到端 4/4、8 张快照、性能复跑（启动 40.9 ms / 平移 P95 0.158 ms，无回归）。
其中**透明通道**是产品负责人真机验收抓出来的缺陷（透明 PNG 显示灰底），已修：
真图到位后元素图层一点底色都不留（真解码与缓存种子两条路径），断言逐像素读
透明角落。若你在真机上看到别的"底色残留"，那是同一族问题，直接报。
证据与逐条明细在 `CODEX_REVIEW_REQUEST_C1.md` §3/§4/§7——**要质疑就去质疑那两份，
不用把绿的重跑一遍**。

## 4. 纪律（与 B1/B2 相同）

- 不提交、不推送、不合并、不打标签、不加版本号（路线图 §6）。
- 不碰 `dev-cc/` 与正式 profile 的数据；测试在 `dev-codex/` 或 `/tmp`。
- 发现问题**先写下来**（复审日志或直接告诉产品负责人/CC），别顺手改——
  两边同时编辑会打架。C1 也没有碰你名下的文件（`InputController` /
  `SelectionController` / `Motion` 一族），当前跑的是 `CanvasInputAdapter` +
  `Canvas/InputController.swift`（`MinimalInputAdapter` 已删除）。
  **注**：C2 期间 `InputController` / `SelectionController` 已由产品负责人
  转给 CC，见 `BATCH_C_TASK.md` §5.1；`Motion` 一族仍归你。
