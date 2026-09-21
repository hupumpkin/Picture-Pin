import CoreGraphics
import Foundation

/// 选择与直接操控的会话状态机（路线图 §4 分工表里的 `SelectionController`）。
///
/// ## 它管什么、不管什么
///
/// - **管**：选择集的增删、点中谁、拖动 / 缩放 / 框选三个会话、覆盖层描述、
///   撤销登记。这五件事共享同一份"按下时记住什么、抬起时清算什么"的状态，
///   拆开会让每个入口都得重新判断"现在是不是在拖"。
/// - **不管**：事件从哪来（`InputController` 负责路由）、相机（平移缩放那条路）、
///   吸附与辅助线（路线图 §3.2 明确归交互精修批次）。
///
/// ## 不 import AppKit
///
/// 会话逻辑必须能在自检里构造输入直接断言（`CanvasInputAdapter` 的协议注释
/// 从批次 A 起就承诺了这件事）。需要 AppKit 才能表达的东西——比如光标形状——
/// 只投递语义值（`CanvasCursor`），由宿主翻译。
///
/// ## 所有权
///
/// 由 `InputController` 持有，**不是**宿主。宿主只持有选择**结果**
/// （`CanvasContext.selection`）：覆盖层、工具栏可用状态、后续 inspector 都要读它，
/// 放在控制器内部会多出一份要同步的副本。
@MainActor
final class SelectionController {

    /// 越过这个距离（视图点）才算拖动。
    ///
    /// 没有它的话，按下时手抖 1 像素就会把元素挪走 1 像素——而"点一下选中"
    /// 是最高频的操作，这种挪动会日积月累地把版面弄歪，而且完全无声。
    static let dragThreshold: CGFloat = 3

    /// 方向键微移的步长（世界单位）。Shift 时 ×10。
    /// 用世界单位而不是屏幕点：微移的意思是"把对齐调准"，那是个版面属性。
    static let nudgeStep: CGFloat = 1

    /// 宿主。**弱引用**——宿主持有 `InputController`，强引用会成环。
    ///
    /// 撤销闭包需要它：撤销发生在若干次操作**之后**，那时早就离开了当初那次
    /// 调用的参数作用域，而 `UndoManager` 只还给我们一个 target（`self`）。
    private weak var context: CanvasContext?

    /// 由 `InputController` 在挂载时调用。
    func attach(to context: CanvasContext) { self.context = context }

    // MARK: - 会话

    private enum Session {
        case idle
        /// 已经按下、但还没越过拖动阈值。此时松手 = 一次点击。
        ///
        /// 起点随会话存：位移要**从按下时**算起，不是从越过阈值那一刻——
        /// 后者会让每次拖动都少掉前 3 个点，手感是"元素追不上手指"。
        ///
        /// `collapseOnClick` 记的是"这次点击要不要把选择收缩成这一个"。
        /// 判据在按下的那一刻就定了（当时是不是已经多选），不是松手时再算。
        ///
        /// `toggleOnClick` 记的是"这次点击要不要把按中的那个移出选择"
        /// （Shift 点已选中的元素）。**同样推迟到松手那一刻才做**，理由见
        /// `pointerDown` 里 Shift 那一段：按下时就把元素移出选择的话，
        /// 想锁轴拖动它的用户会发现图先掉出了选择。
        case pressing(
            hit: CanvasElementID,
            startWorld: CGPoint,
            startView: CGPoint,
            collapseOnClick: Bool,
            toggleOnClick: Bool,
            /// 选择在按下时要立即显示，但只有确认这是“点击”（没有升级为拖动）
            /// 才登记为独立撤销步骤；拖动时它属于该次直接操控的前置状态。
            selectionBefore: Set<CanvasElementID>?
        )
        case moving(
            ids: [CanvasElementID],
            originalFrames: [CanvasElementID: CGRect],
            startWorld: CGPoint,
            changed: Bool
        )
        case resizing(
            id: CanvasElementID,
            handle: SelectionGeometry.Handle,
            originalFrame: CGRect,
            changed: Bool
        )
        case marquee(
            originWorld: CGPoint,
            base: Set<CanvasElementID>,
            selectionBefore: Set<CanvasElementID>,
            current: CGRect?
        )
    }

    private var session: Session = .idle

    /// 正在拖动或缩放（框选不算：它不改场景）。
    /// 宿主与断言用它区分"这一次拖动改了东西没有"。
    var isDirectManipulating: Bool {
        switch session {
        case .moving(_, _, _, _), .resizing(_, _, _, _): true
        default: false
        }
    }

    /// 正在缩放（不是拖动）。断言用它验证"按在外框角上走的是哪条路"——
    /// 少了手柄优先那一步，这里会变成拖动，而画面看起来"也在动"。
    var isResizingElement: Bool {
        if case .resizing = session { return true }
        return false
    }

    // MARK: - 指针

    /// 左键按下。**空白处也由这里处理**（框选）——产品负责人 2026-09-18 定：
    /// 空白拖动 = 框选（Figma / Miro 惯例），平移改走空格 + 拖动 / 中键 / 双指滚动。
    func pointerDown(_ input: CanvasPointerInput, context: CanvasContext) {
        session = .idle

        // 1. 手柄优先。手柄压在外框角上，而外框角同时也在元素内部——
        //    先判元素的话手柄永远点不中（缩小之后手柄就落在图里）。
        if let id = singleSelection(context),
           let frame = context.element(id)?.frame,
           let handle = SelectionGeometry.handle(at: input.viewPoint, of: frame, camera: context.camera) {
            session = .resizing(id: id, handle: handle, originalFrame: frame, changed: false)
            return
        }

        // 2. 元素：选中 + 准备拖动。
        if let hit = context.hitTest(worldPoint: input.worldPoint) {
            // Shift 的两个含义在这里分岔：**点**是切换选择，**拖**是锁轴。
            //
            // 按下这一刻看不出是哪一种，而"按住 Shift 锁轴拖动已选中的元素"
            // 正是 Shift 最常用的场景（产品负责人 2026-09-20 定），所以：
            //
            // - 未选中的：立刻加选。加选之后如果拖起来，就是连它一起挪
            //   （与 Figma 一致：Shift 拖一张没选中的图 = 带着它一起锁轴走）；
            // - 已选中的：**按下时不动选择**，把"移出选择"推迟到松手那一刻
            //   ——没越过阈值才算点击，越过阈值就是锁轴拖动，元素留在选择里。
            //
            // 第一版在按下时就把它移出选择，表现是"按住 Shift 想锁轴拖这张图，
            // 图却先掉出了选择、而且拖不动"，而锁轴拖动正是用户按 Shift 的目的。
            let shift = input.modifiers.contains(.shift)
            var toggleOnClick = false
            let selectionBefore = context.selection
            var selectionChangedOnPress = false
            if shift {
                if context.selection.contains(hit) {
                    toggleOnClick = true
                } else {
                    var next = context.selection
                    next.insert(hit)
                    setSelection(next, context: context)
                    selectionChangedOnPress = true
                }
            } else if !context.selection.contains(hit) {
                setSelection([hit], context: context)
                selectionChangedOnPress = true
            }
            // 已经多选时点其中一个：**先不收缩**。用户很可能是想拖这一组，
            // 收缩放到松手时——那时才知道这是一次点击而不是一次拖动。
            // 先收缩的话，多选之后想整体挪一下就必须重新框一遍。
            let collapse = !shift
                && context.selection.contains(hit)
                && context.selection.count > 1
            session = .pressing(
                hit: hit,
                startWorld: input.worldPoint,
                startView: input.viewPoint,
                collapseOnClick: collapse,
                toggleOnClick: toggleOnClick,
                selectionBefore: selectionChangedOnPress ? selectionBefore : nil
            )
            return
        }

        // 3. 空白：框选。按下即清空（Shift 时保留原选择作为底）。
        let additive = input.modifiers.contains(.shift)
        let selectionBefore = context.selection
        let base = additive ? context.selection : []
        if !additive { setSelection([], context: context) }
        session = .marquee(
            originWorld: input.worldPoint,
            base: base,
            selectionBefore: selectionBefore,
            current: nil
        )
        pushOverlay(context: context)
    }

    func pointerDragged(_ input: CanvasPointerInput, context: CanvasContext) {
        switch session {
        case .idle:
            break

        case .pressing(_, let startWorld, let startView, _, _, _):
            // 越过阈值才升级成拖动：这一条就是"点一下不会挪动元素"的保证。
            let moved = hypot(input.viewPoint.x - startView.x, input.viewPoint.y - startView.y)
            guard moved >= Self.dragThreshold else { return }
            beginMove(
                startWorld: startWorld,
                firstPoint: input.worldPoint,
                modifiers: input.modifiers,
                context: context
            )

        case .moving:
            applyMove(to: input.worldPoint, modifiers: input.modifiers, context: context)

        case .resizing(let id, let handle, let original, _):
            // 默认等比（产品负责人 2026-09-18 定的），Shift 自由拉伸。
            let proportional = !input.modifiers.contains(.shift)
            let frame = SelectionGeometry.resized(
                original, handle: handle, to: input.worldPoint, proportional: proportional
            )
            context.perform(.setFrame(frame, for: id))
            session = .resizing(id: id, handle: handle, originalFrame: original, changed: true)
            pushOverlay(context: context)

        case .marquee(let origin, let base, let selectionBefore, _):
            let rect = SelectionGeometry.rect(from: origin, to: input.worldPoint)
            let hits = Set(context.elements(intersecting: rect))
            // 实时更新：框到哪里高亮到哪里。松手才定稿是另一种手感，
            // 而且框选期间看不到结果就没法中途修正。
            setSelection(base.union(hits), context: context)
            session = .marquee(
                originWorld: origin,
                base: base,
                selectionBefore: selectionBefore,
                current: rect
            )
            pushOverlay(context: context)
        }
    }

    func pointerUp(_: CanvasPointerInput, context: CanvasContext) {
        // **先退出会话，再收拾残局。**
        //
        // 顺序反了会留下一个很难发现的残留：`pushOverlay` 是按**当前会话**
        // 重算覆盖层的，会话还停在 `.marquee` 时它会把刚拖完的那个矩形
        // 原样再画一遍——松手之后框还挂在画布上，直到下一次输入才消失。
        // 自检里"松手后框选矩形消失"抓的就是这个。
        let finished = session
        session = .idle

        switch finished {
        case .moving(_, let originals, _, let changed):
            if changed { registerFrameUndo(originals, actionName: "移动", context: context) }

        case .resizing(let id, _, let original, let changed):
            if changed { registerFrameUndo([id: original], actionName: "缩放", context: context) }

        case .pressing(let hit, _, _, let collapse, let toggle, let selectionBefore):
            // 没越过阈值 = 一次点击。两种"按下时不敢做"的收尾都推迟到这里：
            //
            // - `collapse`：多选时点其中一个 → 收缩成这一个；
            // - `toggle`：Shift 点已选中的那个 → 移出选择。
            //
            // 越过阈值的那些根本走不到这里（`pointerDragged` 已经把会话换成
            // `.moving`），所以"走到这里"本身就是"这是一次点击"的证据——
            // 不需要再比一次阈值。
            //
            // 两者互斥：`collapse` 要求没按 Shift，`toggle` 只在按了 Shift 时才置。
            if toggle {
                var next = context.selection
                next.remove(hit)
                setSelection(next, context: context, recordUndo: true)
            } else if collapse {
                setSelection([hit], context: context, recordUndo: true)
            } else if let selectionBefore {
                registerSelectionUndo(selectionBefore, context: context)
            }

        case .marquee(_, _, let selectionBefore, _):
            registerSelectionUndo(selectionBefore, context: context)
            pushOverlay(context: context)   // 清掉框选矩形

        case .idle:
            break
        }
    }

    /// 悬停位置该显示哪种指针。
    ///
    /// 只回答"手柄上还是不在手柄上"——空格与平移那两个模式由 `InputController`
    /// 决定，它们和选择无关。做成纯函数（不改状态、不设光标）是为了让
    /// "手柄命中区到底对不对"能在自检里直接断言，不必真的晃一次鼠标。
    func cursor(at viewPoint: CGPoint, context: CanvasContext) -> CanvasCursor {
        if let id = singleSelection(context),
           let frame = context.element(id)?.frame,
           SelectionGeometry.handle(at: viewPoint, of: frame, camera: context.camera) != nil {
            return .crosshair
        }
        return .arrow
    }

    // MARK: - 键盘

    /// 返回 `true` 表示已消费。键码判定优先于字符（字符随键盘布局变）。
    func keyDown(_ input: CanvasKeyInput, context: CanvasContext) -> Bool {
        switch input.keyCode {
        case 51, 117:                       // Delete / Forward Delete
            return deleteSelection(context: context)
        case 53:                            // Escape
            guard !context.selection.isEmpty else { return false }
            setSelection([], context: context, recordUndo: true)
            return true
        case 123, 124, 125, 126:            // ← → ↓ ↑
            return nudge(keyCode: input.keyCode, input: input, context: context)
        default:
            // ⌘A 的常规路径是菜单的「全选」（`selectAll:` 走响应链），
            // 这里兜底：菜单项被别的东西吃掉时键盘仍然有效。
            if input.modifiers.contains(.command), input.characters.lowercased() == "a" {
                return selectAll(context: context)
            }
            return false
        }
    }

    @discardableResult
    func selectAll(context: CanvasContext) -> Bool {
        let all = Set(context.scene.elements.map(\.id))
        guard !all.isEmpty else { return false }
        setSelection(all, context: context, recordUndo: true)
        return true
    }

    private func nudge(keyCode: UInt16, input: CanvasKeyInput, context: CanvasContext) -> Bool {
        let ids = orderedSelection(context)
        guard !ids.isEmpty else { return false }
        let step = input.modifiers.contains(.shift) ? Self.nudgeStep * 10 : Self.nudgeStep
        let delta: CGSize
        switch keyCode {
        case 123: delta = CGSize(width: -step, height: 0)
        case 124: delta = CGSize(width: step, height: 0)
        case 125: delta = CGSize(width: 0, height: step)
        default:  delta = CGSize(width: 0, height: -step)
        }

        let originals = frames(of: ids, context: context)

        // 自动重复**不再登记**：按住方向键会连发几十次，每次登记一条的话
        // 撤销要按几十下才退得回去。第一次按下登记的那条正好覆盖整段连发，
        // 这正是按住方向键时想要的撤销粒度。
        if !input.isARepeat {
            registerFrameUndo(originals, actionName: "移动", context: context)
        }
        applyOffsets(delta, to: originals, context: context)
        pushOverlay(context: context)
        return true
    }

    private func deleteSelection(context: CanvasContext) -> Bool {
        let elements = orderedSelection(context).compactMap { context.element($0) }
        guard !elements.isEmpty else { return false }
        let selectionBeforeDelete = context.selection
        context.perform(.remove(elements.map(\.id)))
        setSelection([], context: context)
        registerDeleteUndo(elements, restoringSelection: selectionBeforeDelete, context: context)
        return true
    }

    /// 右键菜单删除指定元素。菜单不一定先改变选择，因此不能偷用
    /// `deleteSelection`；否则用户右键一张未选中的图片，可能删掉的是另一组元素。
    @discardableResult
    func deleteElement(_ id: CanvasElementID, context: CanvasContext) -> Bool {
        guard let element = context.element(id) else { return false }
        let selectionBeforeDelete = context.selection
        context.perform(.remove([id]))
        setSelection(selectionBeforeDelete.subtracting([id]), context: context)
        registerDeleteUndo([element], restoringSelection: selectionBeforeDelete, context: context)
        return true
    }

    // MARK: - 拖动

    /// 越过阈值之后正式进入拖动。原始外框在这里取（不是按下时）：
    /// 没越过阈值的按下永远不会用到这份记录。
    private func beginMove(
        startWorld: CGPoint,
        firstPoint: CGPoint,
        modifiers: CanvasModifiers,
        context: CanvasContext
    ) {
        let ids = orderedSelection(context)
        guard !ids.isEmpty else { session = .idle; return }
        session = .moving(
            ids: ids,
            originalFrames: frames(of: ids, context: context),
            startWorld: startWorld,
            changed: false
        )
        // 修饰键要**原样带过去**：这一次拖动事件就是越过阈值的那一次，
        // 它同样是一次真实的移动。丢掉修饰键的话，一次只有单个拖动事件的
        // Shift 拖动（轨迹采样少、或者拖得很快）不会被锁轴。
        applyMove(to: firstPoint, modifiers: modifiers, context: context)
    }

    private func applyMove(
        to worldPoint: CGPoint,
        modifiers: CanvasModifiers,
        context: CanvasContext
    ) {
        guard case .moving(let ids, let originals, let start, _) = session else { return }
        var delta = CGSize(width: worldPoint.x - start.x, height: worldPoint.y - start.y)

        // Shift 锁轴：按住 Shift 拖动只沿"走得更远"的那一根轴走。
        //
        // 与 Shift 的另一个含义（加选）不冲突：加选发生在**按下时**，
        // 锁轴发生在**拖动中**，两者不会同时被读到。
        // 判据用位移本身而不是手指的瞬时位置——用瞬时位置的话，
        // 换轴的那一刻会跳一下。
        if modifiers.contains(.shift) {
            if abs(delta.width) >= abs(delta.height) { delta.height = 0 } else { delta.width = 0 }
        }

        // 位移从**按下时**的原始外框算，不逐帧累加：累加会把每一帧的
        // 浮点误差攒起来，拖久了元素会慢慢偏离手指。
        var assignments: [CanvasElementFrame] = []
        assignments.reserveCapacity(ids.count)
        for id in ids {
            guard let original = originals[id] else { continue }
            assignments.append(CanvasElementFrame(
                id: id,
                frame: original.offsetBy(dx: delta.width, dy: delta.height)
            ))
        }
        context.perform(.setFrames(assignments))
        session = .moving(ids: ids, originalFrames: originals, startWorld: start, changed: true)
        pushOverlay(context: context)
    }

    /// 微移：同样的位移应用到一组外框上。
    private func applyOffsets(
        _ delta: CGSize,
        to originals: [CanvasElementID: CGRect],
        context: CanvasContext
    ) {
        let assignments = originals.map {
            CanvasElementFrame(id: $0.key, frame: $0.value.offsetBy(dx: delta.width, dy: delta.height))
        }
        context.perform(.setFrames(assignments))
    }

    /// 唯一选中的那个元素。无选择或多选时为 `nil`。
    ///
    /// 手柄与缩放都只认单选：一次拖多个元素的等比缩放在本轮范围外
    /// （见任务单「已知边界」）。多选时**不显示手柄**而不是显示了不响应——
    /// 画出来却拖不动的柄比没有柄更让人困惑。
    private func singleSelection(_ context: CanvasContext) -> CanvasElementID? {
        guard context.selection.count == 1 else { return nil }
        return context.selection.first
    }

    /// 选择集按场景顺序排列。
    ///
    /// **顺序必须确定**：`Set` 的遍历顺序每次运行都可能不同，而它决定了
    /// 命令里 `updated` 的次序——自检里两条一模一样的操作会因为顺序不同
    /// 断言失败，那种失败查起来极其费时。场景顺序天然稳定。
    private func orderedSelection(_ context: CanvasContext) -> [CanvasElementID] {
        context.scene.elements.map(\.id).filter { context.selection.contains($0) }
    }

    // MARK: - 选择与覆盖层

    private func setSelection(
        _ new: Set<CanvasElementID>,
        context: CanvasContext,
        recordUndo: Bool = false
    ) {
        guard new != context.selection else { return }
        let previous = context.selection
        context.selection = new
        pushOverlay(context: context)
        if recordUndo { registerSelectionUndo(previous, context: context) }
    }

    /// 重新提交覆盖层。
    ///
    /// 覆盖层是**瞬态渲染输入**，不是状态：它由当前选择 + 当前会话现场重算，
    /// 不按画布存（换画布时 `CanvasHostView` 会丢掉它，见那里的说明）。
    /// 外部改过选择（换画布、点素材面板）之后由 `selectionDidChange` 调一次，
    /// 否则表现是"选中了但画布上没有任何框"。
    func pushOverlay(context: CanvasContext) {
        var overlay = CanvasOverlay()
        overlay.selectionFrames = orderedSelection(context).compactMap { context.element($0)?.frame }
        if !isMarqueeing, let id = singleSelection(context) {
            overlay.handleFrame = context.element(id)?.frame
        }
        if case .marquee(_, _, _, let current) = session {
            overlay.marquee = current
        }
        context.overlay = overlay
    }

    private var isMarqueeing: Bool {
        if case .marquee = session { return true }
        return false
    }

    // MARK: - 撤销
    //
    // ## 为什么每条逆操作都要"先登记反向、再应用"
    //
    // `UndoManager` 的模型是：登记发生时如果正处于撤销过程中，这条就落进
    // **重做栈**。所以撤销动作体里必须再登记一次相反的操作，重做才有东西可用。
    // 第一版只登记了正向的逆操作，结果是"能撤销，但撤销之后 ⌘⇧Z 没反应"。
    //
    // ## 为什么闭包要跳回主 actor
    //
    // `registerUndo(withTarget:handler:)` 的 handler 是 `@Sendable`：它可以在
    // 任何线程被调用。而画布场景、渲染器、SwiftUI 全在主 actor 上。
    // `UndoManager` 在 AppKit 里实际只在主线程发起撤销，所以
    // `assumeIsolated` 是安全的断言，不是赌博。

    /// 登记一次"把外框放回去"。移动、缩放、微移的逆操作都是它。
    ///
    /// **在操作结束时登记一次**，不是每个增量登记一次——后者要按上百次撤销
    /// 才退得回去（`CanvasContext.undoManager` 的注释里点过名）。
    /// 撤销动作本身也走命令通道（`context.perform`），所以渲染器、SwiftUI
    /// 与数据库三边都跟着走，不会出现"撤销只改了画面"这种半截状态。
    private func registerFrameUndo(
        _ restoreTo: [CanvasElementID: CGRect],
        actionName: String,
        context: CanvasContext
    ) {
        guard !restoreTo.isEmpty, let undo = context.undoManager else { return }
        undo.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                controller.performFrameUndo(restoring: restoreTo, actionName: actionName)
            }
        }
        undo.setActionName(actionName)
    }

    /// 选择也属于用户可见状态：用户明确要求「撤回选中」时，不能只把选择框
    /// 当作不会入历史的临时装饰。框选的连续更新仍只在开始时登记一次，避免
    /// 鼠标移动一百帧占满 15 步历史。
    private func registerSelectionUndo(
        _ restoreTo: Set<CanvasElementID>,
        context: CanvasContext
    ) {
        guard let undo = context.undoManager else { return }
        withUndoGroupIfNeeded(undo) {
            undo.registerUndo(withTarget: self) { controller in
                MainActor.assumeIsolated { controller.performSelectionUndo(restoring: restoreTo) }
            }
            undo.setActionName("选择")
        }
    }

    /// 产品窗口按事件自动分组；但离屏自检会主动关闭该行为来验证“每次动作
    /// 一步”的粒度。选择可以由 Escape 这样的单个按键直接触发，因此这里在
    /// 后者环境补一个最小分组，避免把同一逻辑变成只在测试里会崩的隐患。
    private func withUndoGroupIfNeeded(_ undo: UndoManager, _ body: () -> Void) {
        let needsGroup = !undo.groupsByEvent && undo.groupingLevel == 0
        if needsGroup { undo.beginUndoGrouping() }
        body()
        if needsGroup { undo.endUndoGrouping() }
    }

    private func performSelectionUndo(restoring restoreTo: Set<CanvasElementID>) {
        guard let context else { return }
        registerSelectionUndo(context.selection, context: context)
        setSelection(restoreTo, context: context)
    }

    /// 执行一步"把外框放回去"，并把它的反向登记下来。
    ///
    /// **反向那一份必须在进入这里之后现读，不能在登记时算好存起来。**
    /// 撤销栈上的每一格都得回答"执行我之前是什么样"，而"执行我之前"只在
    /// 将要执行的那一刻才确定：登记时算好的那份只对第一层正确，往下就过期了。
    /// 过期之后的表现是「拖动 → 撤销 → 重做 → 再撤销」第三步没反应——
    /// 因为它照着上一次重做的目标又摆了一遍，而元素本来就在那儿。
    /// 自检里"撤销一次退掉两步微移"抓的就是它。
    ///
    /// 撤销/重做途中 `registerUndo` 会自动落到对侧栈上（系统保证），
    /// 所以这里不必区分自己在撤销还是在重做。
    private func performFrameUndo(
        restoring restoreTo: [CanvasElementID: CGRect],
        actionName: String
    ) {
        guard let context else { return }
        registerFrameUndo(
            frames(of: Array(restoreTo.keys), context: context),
            actionName: actionName,
            context: context
        )
        applyFrames(restoreTo)
    }

    private func applyFrames(_ frames: [CanvasElementID: CGRect]) {
        guard let context else { return }
        let assignments = frames
            .filter { context.element($0.key) != nil }
            .map { CanvasElementFrame(id: $0.key, frame: $0.value) }
        context.perform(.setFrames(assignments))
        // 撤销/重做改的是当前选择里那些元素的外框，覆盖层要跟着走。
        pushOverlay(context: context)
    }

    private func frames(
        of ids: [CanvasElementID],
        context: CanvasContext
    ) -> [CanvasElementID: CGRect] {
        var result: [CanvasElementID: CGRect] = [:]
        for id in ids {
            if let frame = context.element(id)?.frame { result[id] = frame }
        }
        return result
    }

    /// 删除的逆操作是"把元素放回来"（连同原顺序），它自己又登记一次删除作为重做。
    private func registerDeleteUndo(
        _ elements: [CanvasElement],
        restoringSelection: Set<CanvasElementID>,
        context: CanvasContext
    ) {
        guard !elements.isEmpty, let undo = context.undoManager else { return }
        undo.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                controller.performRestore(elements, restoringSelection: restoringSelection)
            }
        }
        undo.setActionName("删除")
    }

    private func performRestore(_ elements: [CanvasElement], restoringSelection: Set<CanvasElementID>) {
        guard let context else { return }
        registerRestoreUndo(elements, restoringSelection: context.selection, context: context)
        context.perform(.restore(elements))
        setSelection(restoringSelection, context: context)
    }

    private func registerRestoreUndo(
        _ elements: [CanvasElement],
        restoringSelection: Set<CanvasElementID>,
        context: CanvasContext
    ) {
        guard !elements.isEmpty, let undo = context.undoManager else { return }
        undo.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                controller.performRemove(elements, restoringSelection: restoringSelection)
            }
        }
        undo.setActionName("删除")
    }

    private func performRemove(_ elements: [CanvasElement], restoringSelection: Set<CanvasElementID>) {
        guard let context else { return }
        registerDeleteUndo(elements, restoringSelection: context.selection, context: context)
        context.perform(.remove(elements.map(\.id)))
        setSelection(restoringSelection, context: context)
    }

    /// 自检探针：当前会话是不是空闲。断言用它区分"点击"与"拖动"。
    var isIdle: Bool { if case .idle = session { return true }; return false }
}
