# 交接：Pin 原生 C2（拖入 / 粘贴 / 直接操控）

> 写于 2026-09-20 · 给**下一个窗口的 CC**（也供产品负责人查阅）
> 读完这一份就能接着干，不需要回翻上一个窗口的对话。
> 事实分三类标注：**【已核】**我实测或读到源码确认 · **【Codex】**Codex 的判定、我只粗查过 · **【未核】**还没查

---

## 2026-09-20 Codex 接手补记（以此为准）

下文是 CC 编写时的历史快照，其中「C1 的 3 个 P1 + 1 个 P2 一条未修」、762 条自检、八张快照未重建和清单未更新等状态已经过期；保留原文作为审查轨迹。

- 【已核】C1 遗留 4 项已在本地返修：存储重试不替换带待写任务的调度器，首次打开失败后可完成恢复；导入结果区分素材入库与画布保存；应用退出前刷盘并在保存失败时取消退出；文件选择器接受所有普通文件，再由 ImageIO 检查内容。切换调试画布也先刷旧画布、保存新画布。
- 【已核】Debug 和独立 Release 应用包构建通过；包内 `--selftest` 810/810。专用 TestAssets 在临时目录无界面导入、库报告通过；8 张快照已重建并检查内容图；Release 包 `build/Pin-codex.app` 的二进制与 `.build/release/PinNative` SHA-256 一致。
- 【未核】真实窗口退出、Finder 选择器点击流程及 C2 原清单中的实机/性能项目仍未人工复测。不要据此宣称整个 C2 已验收。
- 【已核】仍在 `native/pin-macOS/canvas-kernel-a`，基线 `d7680f5`；本轮未提交、未推送、未打标签。测试只用临时数据目录，未操作原有素材。

## 0. 一句话现状

C2 的代码、断言、注入实测都做完了（自检 **762/762**，两个 `.app` 已打包并核对过 SHA），
送审清单已交 Codex。**Codex 于 2026-09-20 复审后判定「暂不验收」**，除 C1 遗留的
3 个 P1 + 1 个 P2 外又提了 4 条新发现。下一步是**返修**，不是加功能。

---

## 1. 硬约束（不可违背，先读这一节）

### 数据与隐私

- **不修改原工作区** `/Users/huwenhao12/Documents/截图分析管理工具`。
- **不读取、不输出、不提交任何真实 API Key**；`.env` 不进 git、不发人、不贴聊天。
- **不把花瓣 Cookie 发到后端，也不写进 Pin 的数据文件**。
- **不读取用户 `screenshots/` 里的截图内容并外传**。
- 原生版**从全新空库开始**：不读取 / 显示 / 迁移 / 移动 / 删除旧的 DesignPeek、
  Pin Web、CC Web 的素材、画布、字体、分析数据（路线图 §6）。
- **测试只用合成素材或专用 TestAssets**，不用旧图库。
- `GITHUB_MAINTENANCE_WORKFLOW.md` §7：`screenshots/`、`data/`、`.env`、真实 Key、
  Cookie、含敏感内容的日志，一律不提交。
- 自检/实验**全部在临时目录跑**，绝不碰真实 profile 数据目录；不得触碰用户真实系统剪贴板。
- `TestAssets/` 里 4 个原始文件已按 `pin-macos-test-NN-` 改名并逐条核对哈希，**不要动**。
- 用户自己启动的 `Pin-cc-debug.app` 进程**不要杀**（曾经差点误杀；`pgrep` 会匹配到
  你自己的命令行，用 `ps -eo pid,etime,comm` 判断）。

### 版本与提交

- 路线图 §6：**日常迭代不加正式版本号、不提交、不推送、不合并、不打标签**。
  当前基线提交 `d7680f5`，本轮改动**全部未提交**。
- 网页版用 `P` 编号、DesignPeek 网页版用 `DP`、原生草案用 `N`。
- **每次产品迭代更新 `截图分析管理工具-native/VERSION_HISTORY.md`**（已更新到 2026-09-20）。
- 改动完成后顺序：**语法检查 → 真机/浏览器验证 → 才谈提交**。

### 端口（网页版那边，别搞混）

原 Pin 用 `8765`，CC 工作区用 `8766`；**不要停止或覆盖原 Pin 服务**。这是
`截图分析管理工具-cc` 那套的事，与本文档的原生工作无关。

### 证据口径（§9）

没有真实证据时，只能写**「未验证」「待人工确认」「本地已提交但未推送」**，
**不能写「已完成」「已发布」**。

---

## 2. 角色与沟通方式

- **产品负责人（用户）= PM + 设计师，不碰实现。** CC 是高级技术工程师。
- **技术问题先翻译成前台影响**再交他判断：说"用户会看到什么"，不说实现细节。
  **纯内部的技术事（重构、测试方法、构建脚本）我自己定**，不必占用他时间。
- **凡断言，先问它能不能红**——一条断言如果在"有缺陷"和"没缺陷"两种情况下都是绿的，
  它就没有牙，等于没写。这个项目对这条要求很严。
- **需要他手动测之前，必须先把 `.app` 重新打包好**再告诉他测；只跑自检不算交付。
  交付话术给**完整可双击路径**，并说明要哪个包。

---

## 3. 工作区与制品（截至 2026-09-20）

| 项目 | 值 |
| --- | --- |
| 工作目录 | `/Users/huwenhao12/Documents/截图分析管理工具-native/pin-macos` |
| 分支 | `native/pin-macOS/canvas-kernel-a` |
| 基线提交 | `d7680f5`（本轮**未提交**） |
| 工作区改动 | 28 个 M、22 个 ??、1 个 D（共 51 项，含本文档） |
| 自检 | **762/762**，Debug / Release 各一遍，**两遍都是从应用包内跑的** |
| release 包 | `build/Pin-cc.app`，包内二进制 SHA `ea1cbed9cbda9900dc5f323b8d81268322d2f5762b5f3b5c0eb57321aec624c2` |
| debug 包 | `build/Pin-cc-debug.app`，包内二进制 SHA `05ddf85d4fe914a9f8f0f209a6470073bf4e98e01d2b4d1528785bd1761c3cf5` |

两个包都是 `com.pin.native.dev-cc`，共用 `~/Library/Application Support/Pin/dev-cc/`。
`cc-debug` 才带演示素材（演示代码在 `#if DEBUG` 里）；`release cc-debug` 会被脚本拒绝。

**`CODEX_HANDOFF_C2.md` 不存在**——Codex 复审时点名过这件事（用户以为有）。
要么补一份，要么别再引用它。

---

## 4. C2 做了什么

送审清单在 **`pin-macos/CODEX_REVIEW_REQUEST_C2.md`**（218 行，八节 + 未验证清单）。
下面是要点。

### 4.1 三条导入通道合流

文件选择器 / Finder 拖入 / ⌘V 粘贴走同一个 `ImportCoordinator` 入口，来源各自标注。

- 位图没有文件，而流水线只认文件 → 位图先落成临时 PNG
  （`Import/TemporaryImageWriter.swift`，`…/pin-paste/<UUID>/<名字>`），导入完即清。
- **`AppKit` 只出现在 `Import/PasteboardReader.swift` 一个文件里**，其余可脱离
  `NSPasteboard` 测试。这是刻意的分层。

### 4.2 直接操控拆成三个文件

`Canvas/SelectionGeometry.swift`（纯几何）、`SelectionController.swift`（选择集与
手势会话状态机）、`InputController.swift`（输入路由）。`MinimalInputAdapter.swift`
**已删除**——路线图 §4 规则 3 禁止两套输入逻辑并存。接缝 `CanvasInputAdapter` 未变。

### 4.3 断言账本 626 → 762

| 新组 | 条数 |
| --- | --- |
| 粘贴通道（§4 第 2 条） | 33 |
| 拖入通道（§4 第 1 条） | 7 |
| 选择几何（手柄、缩放） | 18 |
| 点击选择与框选 | 24 |
| 拖动与缩放元素 | 15 |
| 撤销与重做（直接操控） | 22 |
| 平移方式与光标反馈 | 17 |
| **合计** | **136** |

626 + 136 = **762**。那 626 条一条没删，全部重跑过。

### 4.4 注入实测：11 种缺陷，逐条按名字打红

协议：备份 → 注入 → 编译 → 跑自检 → `grep -F "✗ <断言名>"` → 还原 → 复跑全绿。
缺陷形态与断言名逐条列在送审清单 §4。

**抓到一个真产品缺陷：撤销的反向快照过期。**
反向那一份原先在**登记时**算好存进去，导致：

> 拖动画布上的图片 → 撤销（正常退回）→ **重做，图片没回来**

撤销本身执行的目标始终是对的，错的只是它顺手登记上去的那一份。修法：反向**执行时现读**
（`SelectionController.performFrameUndo` 里先 `frames(of:)` 再 `applyFrames`）。
教训：**这个缺陷只在"重做"那一步显形**，只断言 `canRedo` 而不真的调一次 `redo()` 就抓不到。

### 4.5 一条断言被证明没牙（改的是断言本身）

「位图结果不换成用户看得懂的名字」原来用**正常文件名**验证，而正常名字原样落盘、
原样入库——把改名那一整段删掉它照样绿。补法：换成**带斜杠的名字**
（如 `粘贴 19/30.png`）。磁盘上会被 `TemporaryImageWriter` 换成 `-`（防目录穿越），
而用户看到的那个不该被换；**两者不同，才问得出"库里存的是哪一个"**。补完立刻红。

---

## 5. 我在这一轮里犯的错（请勿重蹈）

写在这里是因为新窗口很可能踩同一批坑。

1. **把单次 `ps` 采样当结论。** 我看注入脚本"0% CPU、3 分钟没动"就判定它卡死、准备杀掉，
   其实进程树显示它正常在跑，那个 `swift-build` 是瞬时快照。**差点杀掉一个正在跑的实测**，
   而且当时树里带着注入补丁、我准备按一个假 PID 去"还原"文件。
   → 判进程状态要看**进程树 + 子进程 + 日志**，不是一次 `ps`。
   （同一类错误先前已吃过一次：`pgrep -f inject1b.sh` 会匹配到我自己包装命令的命令行。）

2. **`swift build` 打印的 `Build complete! (Xs)` 只是 llbuild 那一段，不是整个进程的墙钟时间。**
   我把它当成一回事，据此写下"加 `--disable-automatic-resolution` 从 133 秒降到 0.5 秒"，
   还往 `scripts/build-app.sh` 加了参数和注释。**实测推翻**：无改动的 no-op 构建照样 126 秒；
   `swift package dump-package` 只要 0.23 秒，而 `swift package show-dependencies` 单独跑两次
   是 46.9 秒 / 126.8 秒、**不可缓存**。真正的耗时在**编译之前的依赖图加载**，与源码改没改无关，
   跟 GRDB、跟 git 的 `safe.bareRepository` 都无关。**根因未定位。**
   → 那个改动和注释**已撤回**，`build-app.sh` 回到原样（`git diff` 为空已核）。
   → **构建慢是已知现象，不是你的环境坏了。** 单次构建可能白等 0.5~153 秒。

3. **注入的"期望断言名"要写真的会被打红的那一条。** 我先后 3 次等错了名字
   （第 5/6/9 条）。第 5 条尤其典型：我等的是撤销那一步的断言，而缺陷在**重做**那一步。
   → 症状都是"绿着回来"，**"名字写错"和"断言没牙"给出同一个信号**。等错了别急着改断言，
   先确认那一步到底会不会显形。

4. **断言账目要逐组数出来，不能凭印象。** 我一度写 761（实际 762）：漏了「拖入通道」
   是 7 条不是 6 条，还整行漏掉「平移方式与光标反馈」17 条。数字来源应该是自检输出的
   逐组统计，不是回忆。

5. **测试文件没跑过就先别写进报告。** 本轮 `dropInChannel()` 那 7 条是在注入脚本跑着的时候
   加的，直到注入的构建成功才间接证明它编译得过。

---

## 6. 待办（按优先级）

### P0 —— Codex 2026-09-20 提的 4 条新发现

前两条与损坏库有关，后两条是交互缺陷。**我只粗查了第 1、3、4 条的源码。**

| # | Codex 的判定 | 我的粗查 |
| --- | --- | --- |
| 1 | 损坏库恢复对**所有**打开/迁移失败都隔离重建，可能把**忙锁或临时 I/O 故障**误判成"库损坏" | **源码层面成立**：`LibraryRecovery.open` 是 `catch let error as DatabaseOpenError` 就隔离，没区分"真的坏了"和"暂时打不开" |
| 2 | 同一秒重复隔离时，主库与 `-wal`/`-shm` **各自独立**选唯一文件名，可能拆散同一组备份 | 【未核】 |
| 3 | 菜单 `undo`/`redo` 的发送选择器与画布实现的 `undo:`/`redo:` **不一致** | **源码层面成立**：`PinNativeApp.swift:88/90` 发的是 `#selector(UndoManager.undo)`（无冒号），而 `CanvasHostView.swift:921/925` 实现的是 `@objc func undo(_ sender: Any?)`（`undo:`，带冒号），是**两个不同的选择器** |
| 4 | 预先按住 Shift 拖动**已选中**元素，会先把该元素移出选择，无法锁轴拖动 | **源码层面成立**：`SelectionController.swift:115-122`，Shift 按下时 `removing == true` → 先 `next.remove(hit)`，随后第 122 行 `guard !removing else { return }` 直接返回，**不进入拖动会话**。而"想锁轴拖已选元素"正是最常用 Shift 的场景。<br>**注意这不是删掉那行 guard 就能修**：第 120-121 行的注释写明了它的原意——「Shift 点掉的那个不再进入拖动」，是为了避免"点不掉的元素"的手感。真正的修法是**把 Shift-点击（切换选择）和 Shift-拖动（锁轴）分开**，判据只能是"按下之后有没有真的动"（本项目已有 `dragThreshold`），这正是需要产品负责人拍的一处取舍 |

### P1 —— C1 遗留，本轮一条未修

| # | 判定 | 位置 |
| --- | --- | --- |
| P1-a | 存储失败的"重试"会丢掉待写任务，初次打开失败后也不会恢复库 | `UI/WorkspaceView.swift:158` 仍是 `{ model.prepareStorage() }`；`App/WorkspaceModel.swift:208` 每次调用**新建**一个 `SceneWriteScheduler` 替换旧的 |
| P1-b | 导入成功与画布保存成功没有同一个结果契约 | `App/WorkspaceModel.swift:334` `await flushLibrary()` 不向导入调用方返回失败 |
| P1-c | 退出前强制刷盘未接入应用生命周期 | 全工程没有 `applicationWillTerminate` / `NSApplicationDelegate` |
| P2 | 文件选择器与"只由 ImageIO 判定格式"的口径不一致 | `UI/WorkspaceView.swift:75` 仍是 `allowedContentTypes: [.image]` |

**没擅自动手的理由**：P1-a/P1-b 是**契约**问题（"导入成功"这四个字承诺了什么），
按 §5 该由产品负责人 + Codex 拍；P1-c 要引入 `NSApplicationDelegate`，是生命周期的结构改动。

### P2 —— C2 自己没做完的

- **§4 第 3 条：超长图 / HEIC / 带方向 JPEG 的实机收数**——未做（无硬件/素材）。
- **§4 第 5 条：§2.4 两个待决参数复测**（预加载边距 256 点、512 MB 预算）——未做。
- **§4 第 4 条 损坏库完整形态**：代码写完、编译过、界面接好（顶部警告条 + 导出诊断 +
  在访达中显示），但**没有自检、没有注入、没有实测过一次真正的坏库**。
  → 目前只有"读起来对"，**不要按"已完成"对待**。

### P3 —— 未验证清单（完整版在送审清单 §6）

- 拖放的 AppKit 那一层（`draggingEntered` / `performDragOperation` / `droppedFileURLs`
  按 UTType 过滤、剔除目录）需要真的拖放会话，没有断言；素材面板 `dropDestination` 同理。
  「拖入通道」那 7 条只钉到它**下游**那一步。
- ⌘V 在非画布焦点下会不会落到画布（菜单项 target 为 `nil` 走响应链，画布在
  `viewDidMoveToWindow` 取第一响应者）。
- 素材面板拖入的高亮反馈（SwiftUI `isTargeted` 观感）。
- 真窗口 Liquid Glass 观感（B2/C1 遗留）。
- 几百条素材的滚动性能、大库首次恢复时间（C1 遗留，无数字）。
- 屏幕倍率与鼠标滚轮实机（本机无鼠标）。

### P4 —— 交付标识

- **八张快照未重建**：画布内容与覆盖层都变了，现有快照已不反映当前渲染结果。
- **`BASELINE-A.sha256`（70 个文件）未更新**：现在跑 `--check` 会报大量不匹配。

---

## 7. 关键文件地图

```
pin-macos/
  CODEX_REVIEW_REQUEST_C2.md   ← 本轮送审清单（八节，含未验证清单）
  CODEX_REVIEW_REQUEST_C1.md   ← 上一轮，格式参照
  HANDOFF.md                   ← 1165 行，整体交接
  BATCH_C_TASK.md              ← 628 行，批次 C 任务书（§5.1 有边界变更：InputController/
                                  SelectionController 由 Codex 转 CC，请 Codex 不要再改这两个文件）
  SESSION_HANDOFF_C2.md        ← 本文档
  Sources/PinNative/
    Canvas/SelectionGeometry.swift    新增：手柄位置/命中/缩放外框/选框，纯几何
    Canvas/SelectionController.swift  新增：选择集与手势会话状态机
    Canvas/InputController.swift      新增：输入路由（取代已删除的 MinimalInputAdapter）
    Canvas/LayerRenderer.swift        改：三个 CAShapeLayer（选中框/手柄/选框）+ 探针
    Canvas/CanvasHostView.swift       改：拖入、⌘V、onDropFiles/onPaste 两条通道
    Import/ClipboardPayload.swift     新增：三种剪贴板形态，值类型，不 import AppKit
    Import/PasteboardReader.swift     新增：唯一读 NSPasteboard 的地方
    Import/TemporaryImageWriter.swift 新增：位图落临时 PNG 并清理
    Persistence/LibraryRecovery.swift 新增：打不开就连 -wal/-shm 一起改名再建空库
    Persistence/LibraryDiagnostics.swift 新增：导出诊断正文（纯函数）
    App/WorkspaceModel.swift          改：paste(anchor:)、导入收尾、隔离接线、诊断导出
    UI/WorkspaceView.swift            改：三条通道入口、面板拖入高亮、隔离警告条
    Tools/SelfTest.swift              改：七个新断言组
  scripts/build-app.sh        ← 组装可双击 .app（见下）
```

---

## 8. 常用命令

```bash
cd /Users/huwenhao12/Documents/截图分析管理工具-native/pin-macos

# 构建（可能先白等 0.5~153 秒，见 §5.2；这不是坏了）
swift build

# 自检（762 项）
.build/debug/PinNative --selftest

# 打包成可双击的 .app
./scripts/build-app.sh debug cc-debug     # → build/Pin-cc-debug.app（带演示素材）
./scripts/build-app.sh release cc         # → build/Pin-cc.app（正式包）

# 核对包内二进制与构建产物一致（交付前必做）
shasum -a 256 build/Pin-cc-debug.app/Contents/MacOS/PinNative .build/debug/PinNative

# 从包内跑自检（制品证据）
./build/Pin-cc.app/Contents/MacOS/PinNative --selftest

# 库诊断
.build/debug/PinNative --library-report
```

**注入脚本的写法要点**（本轮踩过）：
- 必须带 `trap restore_all EXIT INT TERM`。`/tmp/inject1b.sh` 漏了这条，
  中途被打断就会把一个**带注入缺陷的树**留在工作区，下一轮打包就把它当正式产物。
- `pgrep -f <脚本名>` 不可靠（匹配到自己的命令行），用 `ps -eo pid,ppid,etime,command` 看进程树。
- 判"有没有打红"用 `grep -F "✗ <断言名>"`；**名字写错和断言没牙给出同一个信号**。

---

## 9. 下一步建议

1. **先返修 P0 那 4 条**（Codex 新提的），这四条都是真缺陷，且第 3、4 条有明确的前台影响：
   - 第 4 条：**用户按住 Shift 拖已选中的图，图会先掉出选择、而且拖不动**——
     而"锁轴拖动"正是 Shift 最常用的场景。
   - 第 3 条：菜单里的撤销/重做**可能根本没走到画布自己的实现上**。
2. 再处理 C1 的 3 P1 + 1 P2（需要产品负责人 / Codex 先拍契约）。
3. 补齐损坏库的自检与注入（P2 第 4 条）——它现在只有代码没有证据。
4. 交付前：重建八张快照、更新 `BASELINE-A.sha256`、重打包两个 `.app` 并核对 SHA、
   从包内跑自检、更新 `VERSION_HISTORY.md`。
5. **不要提交**（路线图 §6：日常迭代不提交、不推送、不发版）。

---

## 10. 相关记忆（跨窗口保留）

- **Pin 终局形态：完全原生 macOS 客户端**——不做网页套壳。
- **站点内嵌可行性**：X-Frame-Options 管不到原生顶层 WebView，花瓣/Pinterest/站酷等可加载。
- **三方角色划分**：产品负责人是 PM+设计师、不碰实现；CC 是高级技术工程师；Codex 独立复核。
- **技术问题先翻译成前台影响**：有前台影响的交他判断，纯内部的我自己定。
- **手动测试前先打包 .app**：只跑自检不算交付；给完整可双击路径。
