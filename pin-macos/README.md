# Pin 原生（macOS）

Pin 的原生 macOS 客户端。同目录下的 `PIN_NATIVE_CANVAS_KERNEL.md`（在 CC 工作区根目录）
是双方对齐的开发路线图，本工程按其中的批次推进。

当前进度：**批次 A — 接口与工程**。

## 环境

- macOS 26 及以上（用到 Liquid Glass 与 `@Observable`）
- Xcode 26 / Swift 6.2 及以上
- 只需要命令行工具链；本工程**不是** `.xcodeproj`

## 为什么用 SPM 而不是 Xcode 工程

`project.pbxproj` 是单文件、含大量 UUID 引用、几乎无法人工合并。本工程由 CC 和 Codex
两个 Agent 并行开发，用 `.xcodeproj` 意味着每次同时改动都要手工解冲突。SPM 的
`Package.swift` 是纯文本、按文件路径而非 UUID 组织，冲突范围小得多。

代价是 SPM 只产出可执行文件、不产出 `.app`，所以用 `scripts/build-app.sh` 补一个
bundle 外壳（`Info.plist` + 二进制）。日常开发用 `swift run` 即可，不需要 bundle。

## 构建与运行

```bash
# 开发运行（会打开窗口）
swift run PinNative

# 打包成 .app
./scripts/build-app.sh          # 产物：build/Pin.app

# 相机与坐标换算自检（无窗口，返回码 0 表示通过）
swift run PinNative --selftest

# 离屏渲染各尺寸截图（无窗口，不抢焦点，不需要屏幕录制权限）
swift run PinNative --snapshot  # 产物：build/snapshots/*.png

# 性能实测报告（路线图 §2.4）。**必须 release**——debug 的 -Onone 会让数字
# 整体偏大一个量级。无窗口，跑完直接退出，结果逐字打印到 stdout。
swift run -c release PinNative --perf-report   # 解读见 PERF_REPORT_B2.md
```

## 数据目录

数据目录固定在 `~/Library/Application Support/Pin/` 下，与旧工作区完全隔离。

| profile | 目录 | 谁在用 |
| --- | --- | --- |
| `cc` | `Pin/dev-cc/` | Claude |
| `codex` | `Pin/dev-codex/` | Codex |
| `production` | `Pin/`（根目录） | 正式版，与开发数据分开 |

两个 Agent 必须用不同 profile：否则同时跑起来会互相覆盖开发数据
（`GITHUB_MAINTENANCE_WORKFLOW.md` §7）。

profile 由两条路决定，**都不需要人工记住设环境变量**：

```bash
# 1. 显式指定（swift run 场景）
PIN_DEV_PROFILE=codex swift run PinNative

# 2. 打包出来的 .app 靠 bundle identifier 自带 profile——双击即可
./scripts/build-app.sh release codex    # build/Pin-codex.app → dev-codex
./scripts/build-app.sh release cc       # build/Pin-cc.app  → dev-cc
./scripts/build-app.sh debug cc-debug   # build/Pin-cc-debug.app → dev-cc（带演示素材，实测用）
./scripts/build-app.sh release production   # build/Pin.app → 正式目录
```

`PIN_DEV_PROFILE` 的取值**必须已知**：拼错会打印原因并以返回码 2 退出，
**不会**静默回退到某个真实 profile。第二路存在的理由正是双击启动的 .app
天生带不了环境变量——第一版因此让 Codex 双击普通 `Pin.app` 就落进 `dev-cc`。

**本工程不读取、不迁移、不修改、不删除**旧 DesignPeek / Pin Web / CC Web 的任何素材、
画布、字体与分析数据（路线图 §6）。原生版从全新空库开始。`--selftest` 里有断言保证
数据目录不会落在任何一个旧工作区路径下。

## 目录结构

```text
Sources/PinNative/
├── App/            进程入口、工作台状态、数据目录隔离
├── Canvas/         画布内核（本批次的重点）
│   ├── Camera.swift            三套坐标空间的换算，纯数学，无动画
│   ├── SceneGraph.swift        元素集合的唯一真相来源，不依赖 CALayer
│   ├── HitTest.swift           命中与空间查询，选择/吸附/辅助线共用
│   ├── CanvasRenderer.swift    渲染器协议 + 增量更新描述
│   ├── LayerRenderer.swift     CALayer 实现：worldLayer + overlayLayer
│   ├── CanvasHostView.swift    NSViewRepresentable 宿主，画背景网格、转发输入
│   ├── CanvasInputEvent.swift  输入值对象（**不 import AppKit**，可脱离测试）
│   ├── CanvasInputAdapter.swift 输入协议 + CanvasContext（给 Codex 替换的接缝）
│   ├── CanvasSceneCommand.swift 场景命令：输入层改场景的唯一入口
│   ├── CanvasEventTranslation.swift NSEvent → 值对象，唯一依赖 AppKit 的一步
│   ├── Board.swift             画布集合与当前画布——多画布的预留接口
│   └── MinimalInputAdapter.swift 临时最小实现（批次 B 由 Codex 取代）
├── Assets/         图片管线：ImageProvider 接缝、解码缓存、合成素材（批次 B1）
├── Materials/      素材来源：描述 + 内容提供者——加来源只改这里
├── Design/         设计令牌：间距、圆角、字号、图标尺寸、配色
├── UI/             来源栏（贴边实色）、浮在画布上的素材面板与工具条、玻璃表面封装
└── Tools/          --selftest 与 --snapshot，都不进正式交互路径
                    另有 DevelopmentCommands.swift（**整个文件在 #if DEBUG 里**）
```

## 两条预留接缝

产品按批次推进，所以这两处**只做接缝、不做功能**——目的是让将来加东西是加法，
不是改结构。

### 加一个素材来源

来源是 `Materials/MaterialSource.swift` 里 `MaterialSourceCatalog.make(environment:)`
的一条数据：标识、标题、图标、两句空状态文案、内容形态、内容提供者。
**视图不认识任何具体来源**，所以加一条数据就够了，不用改 `SourceRail.swift`、
`MaterialPanel.swift` 或任何类型定义（第一版是个 enum 加四处 switch，散在两个文件里）。

内容的读取归提供者：实现 `MaterialProvider` 的 `environment`、`content` 和 `refresh()`
即可。**数据目录要用注入进来的那份，不要自己调 `AppEnvironment.resolve()`**——
那会造出第二处真源，「界面读 dev-cc、面板读 dev-codex」不会有任何编译错误。
状态有四种（`idle` / `loading` / `loaded` / `failed`），因为素材读取天然是异步且可失败的
——失败在界面上必须和"确实没有素材"区分开。花瓣那种要在面板里内嵌浏览的来源，
是内容形态本身不同，加一个 `Surface` case 加一个视图，编译器会盯着你补完。

### 加一块画布

`Canvas/Board.swift` 的 `BoardStore` 从第一天就按"可以有 N 块"来存：场景、相机、选择
都是每块画布各一份。`select` / `addBoard` / `rename` / `remove` 现在就可用且被断言覆盖，
**只是还没有界面**——完整多画布管理属于后续阶段。

按画布分开存不只是为了整齐：共享相机会让另一块画布的内容"跳"到别处；共享选择更糟，
选择里存的是元素 ID，旧画布的 ID 在新画布上不存在，覆盖层会照着空位置画选择框。

## 三套坐标空间

路线图 §4 规则 2 要求冻结的接口。混用是画布类 bug 的主要来源。

| 空间 | 单位 | 原点 | 谁在用 |
| --- | --- | --- | --- |
| `world` | 世界单位 | 画布原点，与缩放无关 | 元素 model、命中、吸附、辅助线 |
| `view` | 视图点 | 画布宿主左上角，y 向下 | 输入事件、覆盖层、手柄尺寸 |
| `screen` | 设备像素 | 同 view | 图片 LOD 解码尺寸 |

元素位置一律存 `world`；任何「多少个屏幕点」的尺寸一律存 `view`。
`CanvasCamera` 只提供显式换算，不提供隐式运算。

## 给 Codex 的接口说明

批次 A 冻结了以下接缝，替换实现时不需要改动其它文件：

- **`CanvasInputAdapter`** — 输入的唯一入口。宿主视图只转发原始 `NSEvent`，
  翻译成 `CanvasInputEvent.swift` 里的值对象后交给适配器；适配器**看不到 AppKit**，
  所以交互逻辑可以在自检里构造输入直接断言。写 `Canvas/InputController.swift`
  实现该协议后，改 `CanvasHostView.makeCoordinator` 里的一行即可接管。
  **不要保留两套同时生效的事件逻辑**（路线图 §4 规则 3）。
- **`CanvasContext`** — 适配器读写画布状态的通道，四组：查询
  （`scene` / `hitTest` / `elements(intersecting:)` / `contentBounds`）、
  命令（`perform(_:)` 收 `CanvasSceneCommand`）、选择（`selection`）、
  覆盖层（`overlay`），外加 `undoManager`。第一版只有相机与重绘，
  不足以实现选择、框选、元素拖拽与快捷键——那等于没有接缝。
- **`MotionConfiguration`** — 参数注入点。字段只声明**真有消费者**的那些：
  缓动时长/曲线/降低动态效果，以及 `Feel` 一组的直接操控手感
  （平移倍率、鼠标滚轮行→点换算、捏合灵敏度、⌘+滚轮缩放灵敏度、步进倍数、
  动画帧间隔）。手感数字全部收在这里，调用点里没有字面量。
  `viewportPreloadMargin` 是唯一的例外，**它现在没有消费者**（视口虚拟化属于 B2），
  文档里明写了这一点。完整的按场景参数模型属于 `Canvas/Motion.swift`。
- **`CanvasRenderer`** — `LayerRenderer` 的元素图层生命周期（建 / 改 / 删 / 重排）
  已完整实现，`apply(_:)` 的增量语义是通的。批次 B1 起 `contents` 承载真图片，
  像素一律走 `ImageProvider`（渲染器不自己解码、也不自己缓存）。
  `init(images:)` **刻意没有默认值**：有默认值的话"忘了接线"会编译通过，
  而表现是画布上什么都不显示。
- **`CanvasCommandRelay`** — 工具条命令必须经过输入适配器，不能直接改相机。
  否则按钮缩放会缺动画、缺打断，且替换输入实现时会成为漏网之鱼。

## 已知限制（批次 A）

- **默认启动仍是空白画布**（产品行为）：图片管线通了，但画布上的内容只能靠
  **调试菜单**（`⌘⇧D` 插入演示素材、`⌘⇧B` 新建画布并放入素材）放进去，
  release 构建里没有这个菜单。真正的素材导入属于批次 C。
- 图片管线（批次 B1）有档位与缓存，但**没有迟滞、没有视口虚拟化、没有内存压力响应**，
  也没有性能数字——这些是 B2。`refreshImageTiers()` 目前是 O(元素数) 的线性扫描。
- 输入只有：滚轮/触控板平移、捏合缩放、拖拽平移、按钮缩放、定位内容。
  选择、框选、多选、拖拽元素、快捷键的**通道已就绪但入口为空**，属于批次 B/C。
- 覆盖层通道通了但**不绘制**：`CanvasOverlay` 只被渲染器收下，选择框与手柄的画法
  要和选择模型一起定（批次 C）。
- 右键菜单未接：事件已转发到适配器，但菜单内容未定，弹出口子等定了再加。
- 素材面板、来源栏只有外壳与空状态；素材读取、导入、拖拽属于批次 C。
  面板现在由 `MaterialProvider` 驱动、走的是真实状态机，但提供者仍是占位实现，
  条目列表的渲染也没有经过真实素材的验证（没有素材库可读）。
- **多画布没有界面，也没有持久化**：`BoardStore` 的管理操作可用且被断言覆盖，
  但用户点不到，重启后只剩初始的一块画布。切换画布时会**丢弃覆盖层**——
  覆盖层是宿主全局状态，旧画布的选择框在新画布上对应的位置没有元素。
- 手柄光标反馈、选择框样式等属精修范围，未做。

## 验证

```bash
swift run PinNative --selftest   # 380 项断言：坐标换算、锚点稳定、网格换挡、命中顺序、
                                 # 场景→渲染器闭环、命令与覆盖层通道、素材来源目录、
                                 # 画布集合、环境注入、路径隔离、解码档位与缓存账面、
                                 # 图片真的进了图层、换画布不重解码、
                                 # 手感参数逐个接线、画布不越界、
                                 # 浮层在画布之上（含工具条居中与否）、
                                 # 像素需求的三条来源（外框/缩放/屏幕倍率）各自触发重算、
                                 # 换素材会换像素、重算不等于重发、
                                 # 换档迟滞（升级立刻 / 降级要余量）、视口虚拟化把图层数钉住、
                                 # 缓存预算与内存压力收缩、过期解码在开始前被取消、
                                 # 性能探针默认关着（跑完整个自检一个样本都没记）
swift run PinNative --snapshot   # 1024×700 / 1280×800 / 1440×900 × 浅色深色
                                 # + 有内容的 1280×800（套相机）
                                 # + 不套相机的 1280×800（暴露越界用）
                                 # 后两张仅 debug 构建有
./scripts/manifest.sh --check    # 交付快照校验
```

`--snapshot` 走的是和真实窗口同一套布局与绘制代码，因此它验证的是真实渲染路径，
不是另一套演示代码。

### 已验证

| 项 | 方式 | 结果 |
| --- | --- | --- |
| 坐标换算、锚点稳定、缩放上下限 | `--selftest` | 380/380 通过 |
| 布局（三档尺寸 × 深浅） | `--snapshot` | 无重叠、无溢出 |
| 场景 → 渲染器 → 图层闭环 | `--selftest` 读真实 CALayer 树 | 初始非空 / 插入 / 更新 / 删除 / 重排 / 换画布全部通过 |
| 缺陷回归（P1-01） | 故意改回缺陷后重跑 | 挂掉 7 条断言 |
| 缺陷回归（换画布 / 选择回音 / 共享相机 / 提供者默认值） | 逐一注入后重跑 | 分别挂掉 2 / 2 / 1 / 3 条断言 |
| 缺陷回归（换画布清覆盖层 / 提供者自解析环境 / 模型自解析环境） | 逐一注入后重跑 | 分别挂掉 1 / 2 / 3 条断言 |
| 缺陷回归（B1 十条：选档只看宽度 / 不设档位上限 / 按精确尺寸解码 / 缺素材报成失败 / 解码留在主线程 / 大图自淘汰 / 记账口径 / 缓存不命中 / 重复发请求 / 迟到结果不丢弃） | 逐一注入后重跑 | 分别挂掉 1 / 1 / 4 / 1 / 1 / 2 / 1 / 6 / 1 / 1 条断言 |
| 图片真的进了图层（不是渲染器记账） | `--selftest` 读 `layer.contents` | 尺寸等于档位尺寸、无失败原因 |
| 换档不清空 | `--selftest` 读换档那一瞬间的图层 | 换档瞬间仍是旧档像素（不闪白） |
| 迟到结果被丢弃 | 造可控竞态：粗档拖慢 0.5 秒 | 细档先到后画面**没有**被换回糊的 |
| 解码不在主线程 | `--selftest` 探 `pthread_main_np()` | 否（§2.4 主线程 P95 < 8ms 的前提） |
| 图片显示与比例 | `--snapshot` 套相机那张 | 16 张合成素材，16:9 / 3:2 / 竖图比例均未被拉伸 |
| 画布不越界（画到左侧面板上） | `--snapshot` 不套相机那张 + `--selftest` 读 `layer.masksToBounds` | 注入原 bug 后快照**如实复现**越界，修复后内容被切在画布左边界 |
| 手感参数逐个有消费者 | `--selftest` 注入特征值看行为变化 | 6 个字段各 1–2 条断言；注入"无视参数"后对应断言变红 |
| 画布是基底、浮层在它上面 | `--selftest` 搭真实窗口读视图树 + 命中测试 | 画布铺满来源栏右侧全部宽度；面板底下是画布但点得到面板 |
| 工具条居中在看得见的画布上 | `--selftest` 扫底部一行数浮层命中段（1280 / 960） | 两个宽度都正中；去掉对称占位后两侧分别红出 688≠812、528≠652 |
| 帧间隔真的在控制缓动节奏 | `--selftest` 用只计数的 `CanvasContext` 数帧 | 200ms→1 帧、2ms→一二十帧；把间隔写死后三条全红 |
| Liquid Glass 的观感 | **只能真窗口看** | `cacheDisplay` 快照**拍不出**玻璃材质（见 HANDOFF「玻璃为什么拍不出来」） |
| 换画布不重解码 | `--selftest` 读提供者解码次数 + `⌘⇧B` 手动 | 断言通过；**手感待人工确认** |
| 清单文件集合校验 | 真实树造未登记文件、探针树删文件 | 两个分支都报出文件名并退出 1 |
| 数据隔离（P2-02） | 双击打包的 `.app` 实测 | `Pin-codex.app` 只建 `dev-codex`，`dev-cc` 时间戳不变 |
| profile 闸门 | `PIN_DEV_PROFILE=codxe` | 打印原因、返回码 2、不建目录 |
| `worldLayer` 子层渲染与翻转方向 | 离屏渲染参照图形 | 方向正确、网格与图形对齐 |
| 相机平移缩放手感、图层跟手性 | **用户实机操作** | 「够丝滑」，2026-09-16 |
| 像素需求的三条来源各自触发重算（复审 P1） | `--selftest` 走真实路径：工具条缓动放大 / 触控板捏合 / 屏幕倍率变化 | 修复前分别红出「仍是 960×540」，修复后换成独立算出的 3840×2160 / 1920×1080 / 864×558 |
| 换素材会换像素（复审 P1） | `--selftest` 同档位换素材，读 `layer.contents` 实际尺寸 | 修复前仍是旧图的 960×540；修复后 864×558（两个合成素材同档不同像素） |
| 重算不等于重发 | `--selftest` 平移后数提供者请求次数 | 请求次数不涨（重算挂在相机 setter 上之后仍不涨） |
| 画布名规则只有一条 | `--selftest` 注入空白名 | `rename` 与 `addBoard` 同一规则；把 `addBoard` 改回原样后 2 条变红 |
| 换档迟滞不对称（B2） | `--selftest` 把整条缩放轨迹喂进纯函数 `LODTier.settled` | 升级立刻、降级逐级要余量；余量设 1 时退化成 B1 行为 |
| 迟滞真的接在渲染器上（B2） | `--selftest` 把渲染器调用点的余量写死成 1 再跑 | 「缩到 2/3 倍时档位不动」转红——纯函数那组证明不了调用点用的是它 |
| 视口虚拟化把图层数钉住（B2） | `--selftest` 1000 元素平移 | 建层数 ≤ 视口+边距内元素数，与场景总元素数无关；移出视口丢层、移回来重建 |
| 缓存预算与内存压力（B2） | `--selftest` 调 `ImageCache.handle` 走产品入口 | 预算逐级收缩、存量跟着降到预算内、收缩单向不可回涨 |
| 过期解码在开始前被取消（B2） | `--selftest` 用拖慢档位的提供者造时间窗 | 换档 / 移出视口两条路径都取消成功，被取消的那档没进缓存、没解码 |
| 性能探针默认关着（B2） | 把 `isEnabled` 默认值改成 `true` 再跑 | 3 条转红，并报出"记了 251 次计数、4 段耗时" |
| §2.4 的每帧主线程耗时（B2） | `--perf-report`（release）+ `PERF_REPORT_B2.md` | 1000 元素平移 P95 0.312 ms、全可见 0.586 ms；提交 P95 < 0.02 ms |
| 帧率 / 玻璃材质开销 | **只能真窗口 + Instruments** | **未验证**，见 `PERF_REPORT_B2.md` §5 |

手感一项是用临时参照图形（红方块／黄圆／蓝三角，支持拖动与拖角缩放）实测的。
图形挂在 `worldLayer` 下走真实相机变换、并关闭了隐式动画，所以测到的就是真实
路径的手感，不是演示代码。验证通过在验证后整体删除。
