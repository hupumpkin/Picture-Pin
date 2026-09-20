# Pin 原生批次 A 独立审核

> 审核日期：2026-09-16
> 审核人：Codex
> 对照文档：`PIN_NATIVE_CANVAS_KERNEL.md`、`pin-macos/HANDOFF.md`
> 工作区：`/Users/huwenhao12/Documents/截图分析管理工具-native`
> 分支：`native/pin-macOS/canvas-kernel-a`
> 基线：`bfe2fd21d44eb9504072e6864479cad7ed1a78ad`
> 审核结论：**暂不通过批次 A 出口；完成 P1 返修并冻结交付快照后复审。**

## 1. 已验证事实

- 最终状态下 Debug 与 Release 构建均通过；工具链实测为 Xcode 26.5、Swift 6.3.2，Package tools version 为 6.2。
- `PIN_DEV_PROFILE=codex swift run PinNative --selftest`：81/81 项断言通过。
- `--snapshot`：重新生成 1024×700、1280×800、1440×900 的深浅模式共 6 张快照；未见重叠、截断或画布空白。
- `scripts/build-app.sh debug` 可生成 `build/Pin.app`，应用可启动，来源切换、素材空状态与底部工具栏可被系统辅助功能识别。
- `.build/` 与 `build/` 已被 `pin-macos/.gitignore` 排除；未发现 API Key、Cookie 或用户截图进入交付文件。
- 本次没有读取、迁移、移动或删除旧 DesignPeek / Pin Web 素材。测试应用只使用原生版 Application Support 开发目录。
- 未做性能验证，符合批次 A 边界；触控板真实手感仍待人工确认。

## 2. 阻断问题

### P1-01 场景变化没有传给渲染器，批次 B 元素将无法出现

`CanvasHostView.Coordinator.applyExternalScene` 在场景 revision 变化时只发送 `order` 和当前相机，没有发送 `inserted`、`updated`、`removed`。协调器初始化时也没有把已有元素做一次完整插入。与此同时，`LayerRenderer` 的元素图层入口只会从这些增量数组创建或更新图层。

因此，只要批次 B/C 往 `CanvasScene` 放入第一个元素，SwiftUI 虽然拿到了新 scene，渲染器仍不会收到该元素；非空初始场景也不会显示。当前 81 项自检只验证场景数学和命中，没有覆盖“场景 → 渲染器 → 图层”的闭环。

返修条件：在进入批次 B 前明确并实现一种单一同步契约：

1. 上层把 `CanvasSceneChange` 原样交给宿主 / 渲染器，并提供首次完整同步；或
2. 宿主保存上一场景并可靠地产生完整差异；或
3. 渲染器提供明确的全量 reconcile 接口。

无论采用哪种方案，都要增加“初始非空场景”和“插入 / 更新 / 删除 / 重排”的渲染通道测试。

涉及位置：

- `Sources/PinNative/Canvas/CanvasHostView.swift:139`
- `Sources/PinNative/Canvas/CanvasRenderer.swift:7`
- `Sources/PinNative/Canvas/LayerRenderer.swift:94`

### P1-02 冻结的输入接缝不足以承接 Codex 的交互职责

交接文档称 Codex 只需在 `CanvasHostView` 替换一行即可接管输入，但当前 `CanvasContext` 只暴露相机、视口、动效配置、坐标换算和重绘：没有场景查询、命中、场景动作、选择状态、覆盖层提交或撤销命令通道。`CanvasInputAdapter` 也只接收滚动、捏合和左键三段事件；宿主没有转发键盘、修饰键、右键、悬停等事件。

结果是后续 `InputController` 无法仅通过冻结接口完成路线图中已归 Codex 的选择、框选、多选、元素拖拽和快捷键。要实现它们必然修改 CC 所有的 `CanvasHostView.swift` / `CanvasInputAdapter.swift`，与“只替换一行”和文件所有权约定冲突。

返修条件：在进入批次 B 前二选一并写回交接：

1. CC 扩充稳定的场景 query / command / overlay 通道和必要事件转发；或
2. 明确把 `CanvasHostView.swift` 与 `CanvasInputAdapter.swift` 一并移交 Codex，不再宣称当前协议已冻结。

建议把 AppKit 原始事件转成可测试的输入值对象，再由单一控制器消费；不要让第二套事件逻辑旁路适配器。

涉及位置：

- `Sources/PinNative/Canvas/CanvasInputAdapter.swift:8`
- `Sources/PinNative/Canvas/CanvasInputAdapter.swift:38`
- `Sources/PinNative/Canvas/CanvasHostView.swift:163`
- `Sources/PinNative/Canvas/CanvasHostView.swift:231`

### P1-03 交接不是不可变快照，审核期间出现过无法编译的中间态

整个 `pin-macos/` 仍是未跟踪目录，没有本批次提交号或补丁哈希。审核期间源文件被并发加入并撤回 `TestShapes`；第一次 Release 构建因 `testShapes` 未定义而失败，改动落定后重跑才通过。

这不是最终代码的编译缺陷，但说明当前审核无法绑定到一个稳定交付物。后续任何“已通过”结论都可能在读取下一文件时失效。

返修条件：复审前停止并发编辑，并提供一个不可变标识。可选方式为本地临时提交，或在不提交的情况下记录完整文件清单与 SHA-256 清单；交接后如需继续实验，另开工作区或分支。

## 3. 非阻断问题

### P2-01 基础 UI 尚未完全达到路线图约定

六张快照布局稳定，但来源栏没有 Pin 品牌信号；“字体”来源使用 `textformat` 后，在当前中文系统中视觉上显示为“格式”，与功能名称不一致。路线图 §3.1 明确要求 Pin 品牌、来源栏和素材面板具有清楚层级，因此这部分应由 CC 在基础 UI 验收前修正，而不是留作 Codex 的精修债务。

涉及位置：`Sources/PinNative/UI/SourceRail.swift:19`、`Sources/PinNative/UI/WorkspaceView.swift:21`。

### P2-02 双 Agent 数据隔离依赖人工正确设置环境变量

`PIN_DEV_PROFILE` 缺失或拼错都会静默回退到 `.cc`。从 Finder 双击打包后的 `Pin.app` 时无法自然附带该环境变量，因此 Codex 若按普通应用方式启动，也会落入 `dev-cc`。批次 A 只创建空目录，当前没有素材损失；进入持久化阶段后会产生真实覆盖风险。

返修建议：Debug 构建使用显式启动参数、不同 bundle identifier / scheme，或对未知 profile 直接报错；正式产品 profile 与 `dev-cc` / `dev-codex` 分开。

涉及位置：`Sources/PinNative/App/AppEnvironment.swift:34`。

### P2-03 数据目录创建错误被静默吞掉

应用入口使用 `try?` 创建数据目录。当前空画布不会暴露失败，但进入导入与保存后会表现为“界面正常、数据不落盘”。建议在批次 C 前接入可见错误和重试状态。

涉及位置：`Sources/PinNative/App/PinNativeApp.swift:32`。

## 4. 复审出口

完成以下事项后，批次 A 可以快速复审：

- 修复 P1-01，并增加场景到渲染器的闭环测试。
- 对 P1-02 明确接口扩充或文件所有权移交方案。
- 冻结可复现的交付快照，更新 `HANDOFF.md` 的文件数、最终标识和验证结果。
- 修正来源栏品牌入口与“字体 / 格式”表意。
- 重跑 Debug、Release、81 项自检、六张快照和真实触控板手感检查。

本报告不包含代码修复，不代表批次 B 已开始，也不构成正式版本发布。
