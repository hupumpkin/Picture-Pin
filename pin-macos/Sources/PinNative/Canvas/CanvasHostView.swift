import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 画布宿主：把 AppKit 画布嵌进 SwiftUI。
///
/// SwiftUI 负责窗口、来源栏、面板和工具栏；画布这一块是 AppKit + Core Animation
/// （路线图 §2.1）。两者通过 `CanvasHostView` 的入参和回调通信，SwiftUI 侧不认识
/// CALayer。
///
/// ## 输入的流转方向
///
/// ```text
/// CanvasHostNSView   只转发原始 NSEvent，不解释
///       ↓
/// Coordinator        翻译成值对象（唯一依赖 AppKit 的一步）+ 持有场景/选择/覆盖层
///       ↓
/// CanvasInputAdapter 只消费值对象，可以脱离 AppKit 测试
///       ↓
/// CanvasContext      读状态、发命令、提交覆盖层
/// ```
struct CanvasHostView: NSViewRepresentable {
    /// 相机。SwiftUI 持有，宿主在直接操控时本地先行、随后回调同步回来。
    let camera: CanvasCamera
    let scene: CanvasScene
    /// 当前画布选中的元素。
    ///
    /// 和相机、场景一样**从 SwiftUI 往下传**，理由是多画布：切换画布时，
    /// 旧画布的选择里存的是旧画布的元素 ID，留在宿主里会照着空位置画选择框。
    /// 存进 `BoardStore` 再传下来，切画布就自动换成了新画布的那一份。
    let selection: Set<CanvasElementID>
    let tool: CanvasTool
    let showsGrid: Bool
    let configuration: MotionConfiguration
    /// 撤销深度是可注入的画布配置；默认值集中在 `CanvasUndoConfiguration`。
    let undoConfiguration: CanvasUndoConfiguration = .default
    /// 像素从哪来。由 `WorkspaceModel` 持有并注入——**渲染器不自己建一个**，
    /// 否则素材面板和画布会各缓存一份解码结果（见 `ImageCache` 的说明）。
    let images: any ImageProvider
    /// 工具栏命令的接收端。协调器在建立时把自己接上去。
    let commands: CanvasCommandRelay
    /// 直接操控或命令通道造成的场景变化。SwiftUI 侧据此更新自己的副本。
    let onSceneChange: (CanvasScene) -> Void
    /// 选择变化。批次 A 恒为空——选择逻辑属于 Codex 的 `SelectionController`。
    let onSelectionChange: (Set<CanvasElementID>) -> Void
    /// 直接操控过程中持续回调，用于工具栏的缩放百分比等显示。
    let onCameraChange: (CanvasCamera) -> Void
    /// 东西被拖进画布（§4 第 1 条）。参数是**载荷**与**落点**（世界坐标）。
    ///
    /// ## 为什么是 `ClipboardPayload` 而不是 `[URL]`
    ///
    /// 拖进画布的现在有两种东西：访达拖来的**文件**，和网页里拖来的**位图**。
    /// 后者没有原文件——浏览器给的是图片数据，落盘前得先编码（见
    /// `ClipboardPayload`）。这正是粘贴通道早就遇到过的那两种形态，所以这里
    /// 直接复用同一个类型，而不是再给拖入单开一条"位图路径"：两条路径分开的话，
    /// 尺寸上限、失败清理、落点换算就会各写一遍，然后慢慢走散。
    ///
    /// 返回的是「收不收」，不是「导没导成」：`performDragOperation` 必须当场
    /// 回答，而导入是异步的。返回 `true` 只表示"这批东西我接下了"，
    /// 具体成败由提示胶囊负责——失败也绝不会静默。
    let onDrop: (ClipboardPayload, CGPoint) -> Bool
    /// ⌘V（§4 第 2 条）。**没有落点参数**：粘贴落在视口中心，
    /// 剪贴板里的东西本来就没有"从哪儿拖来"这回事。
    let onPaste: () -> Void
    /// 编辑入口只对真实 SVG 素材开放；位图虽然同样是画布的 `.image` 元素，
    /// 但没有 SVG DOM，不能让它们露出一个无效的编辑动作。
    let canEditSVG: (CanvasElementID) -> Bool
    let onEditSVG: (CanvasElementID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            camera: camera,
            scene: scene,
            selection: selection,
            configuration: configuration,
            images: images,
            commands: commands,
            onSceneChange: onSceneChange,
            onSelectionChange: onSelectionChange,
            onCameraChange: onCameraChange,
            onDrop: onDrop,
            onPaste: onPaste
        )
    }

    func makeNSView(context: Context) -> CanvasHostNSView {
        let view = CanvasHostNSView()
        view.context = context.coordinator
        view.undoConfiguration = undoConfiguration
        view.canEditSVG = canEditSVG
        view.onEditSVG = onEditSVG
        context.coordinator.attach(to: view)
        context.coordinator.setTool(tool)
        view.undoConfiguration = undoConfiguration
        view.canEditSVG = canEditSVG
        view.showsGrid = showsGrid
        return view
    }

    func updateNSView(_ view: CanvasHostNSView, context: Context) {
        context.coordinator.onCameraChange = onCameraChange
        context.coordinator.onDrop = onDrop
        context.coordinator.onPaste = onPaste
        context.coordinator.setMotionConfiguration(configuration)
        context.coordinator.applyExternalCamera(camera)
        context.coordinator.applyExternalScene(scene)
        // 场景之后：换画布时先让渲染器重建内容，再落新的选择。
        context.coordinator.applyExternalSelection(selection)
        context.coordinator.setTool(tool)
        view.showsGrid = showsGrid
    }

    @MainActor
    final class Coordinator: CanvasContext {
        private weak var view: CanvasHostNSView?
        private let renderer: LayerRenderer
        /// 输入路由与直接操控。
        ///
        /// 路线图 §4 规则 3 的替换点就是这一行：宿主只认 `CanvasInputAdapter`
        /// 协议，换实现不必改其他任何地方。批次 A 的临时件
        /// （`MinimalInputAdapter`）已经删除——禁止两套事件逻辑并存。
        private let input = InputController()

        /// 场景的唯一真相来源（宿主这一侧）。
        ///
        /// `private(set)` 不需要额外说明：写只能经 `perform(_:)` 或
        /// `applyExternalScene(_:)`，两条路都会同步渲染器与 SwiftUI，
        /// 外部直接赋值会让三边分叉。
        private(set) var scene: CanvasScene
        /// **已经同步给渲染器的场景。** 差异计算以它为基准。
        ///
        /// 用独立的一份而不是读渲染器的内部状态：渲染器可以忽略空增量、
        /// 可以有自己的缓存，拿它当基准迟早会分叉；而"上一次同步过去的到底是什么"
        /// 只有宿主知道。
        private var syncedScene: CanvasScene

        private let commands: CanvasCommandRelay
        private let onSceneChange: (CanvasScene) -> Void
        private let onSelectionChange: (Set<CanvasElementID>) -> Void
        /// 拖入与粘贴的落点（§4）。`var` 的理由和 `onCameraChange` 一样：
        /// SwiftUI 每次刷新都可能给出新的闭包。
        var onDrop: (ClipboardPayload, CGPoint) -> Bool = { _, _ in false }
        var onPaste: () -> Void = {}
        /// 最近一次对外报告过的相机，用于识别 updateNSView 传来的值是不是回音。
        private var reportedCamera: CanvasCamera

        var onCameraChange: (CanvasCamera) -> Void
        var motionConfiguration: MotionConfiguration

        var camera: CanvasCamera {
            get { renderer.camera }
            set {
                guard newValue != renderer.camera else { return }
                renderer.camera = newValue
                reportedCamera = newValue
                onCameraChange(newValue)
            }
        }

        var viewportSize: CGSize { renderer.camera.viewportSize }

        // MARK: 场景查询

        var contentBounds: CGRect { scene.contentBounds }

        func element(_ id: CanvasElementID) -> CanvasElement? { scene.element(id) }

        func hitTest(worldPoint: CGPoint) -> CanvasElementID? {
            CanvasHitTest.topmostElement(at: worldPoint, in: scene)
        }

        func elements(intersecting worldRect: CGRect) -> [CanvasElementID] {
            CanvasHitTest.elements(intersecting: worldRect, in: scene)
        }

        // MARK: 场景命令

        func perform(_ command: CanvasSceneCommand) {
            let change: CanvasSceneChange
            switch command {
            case .insert(let element):
                change = scene.insert(element)
            case .remove(let ids):
                change = scene.remove(ids)
            case .setFrame(let frame, let id):
                change = scene.setFrame(frame, for: id)
            case .setFrames(let assignments):
                change = scene.setFrames(assignments)
            case .restore(let elements):
                change = scene.restore(elements)
            case .bringToFront(let ids):
                change = scene.bringToFront(ids)
            }
            guard !change.isEmpty else { return }

            // 场景动作自己算好的差异就是权威版本，直接送渲染器；
            // `syncedScene` 同步跟进，避免下一次 `applyExternalScene` 重复送一遍。
            syncedScene = scene
            renderer.apply(CanvasRenderUpdate(change: change))
            onSceneChange(scene)
            requestRedraw()
        }

        // MARK: 选择与覆盖层

        var selection: Set<CanvasElementID> = [] {
            didSet {
                guard selection != oldValue else { return }
                // 由外部推下来的值不回报：它本来就来自 SwiftUI 侧，回一下等于把
                // 同一份数据原样传回去；而且 `applyExternalSelection` 是在
                // `updateNSView` 里被调用的，那时改 SwiftUI 状态会触发
                // 「Modifying state during view update」。
                guard !isApplyingExternalSelection else { return }
                onSelectionChange(selection)
                // 选择框不长在这里：覆盖层由输入层显式提交（`overlay`），
                // 因为"选中元素的外框"和"手柄怎么画"是两件事，混在一起会让
                // 手柄样式散落在宿主里。选择逻辑属于 `SelectionController`。
            }
        }

        private var isApplyingExternalSelection = false

        /// SwiftUI 侧推下来的选择。
        ///
        /// 存在的理由是换画布：选择里存的是元素 ID，旧画布的那些 ID 在新画布上
        /// 根本不存在，留着会让覆盖层照着空位置画选择框。
        func applyExternalSelection(_ selection: Set<CanvasElementID>) {
            guard selection != self.selection else { return }
            isApplyingExternalSelection = true
            self.selection = selection
            isApplyingExternalSelection = false
            // 覆盖层由输入层提交。外部改完选择必须让它重算一次，否则
            // 表现是"选中了但画布上没有任何框"——点素材面板、换画布都会走到这里。
            input.selectionDidChange(context: self)
        }

        var overlay: CanvasOverlay = .empty {
            didSet {
                guard overlay != oldValue else { return }
                renderer.apply(CanvasRenderUpdate(overlay: overlay))
            }
        }

        var undoManager: UndoManager? { view?.window?.undoManager }

        init(
            camera: CanvasCamera,
            scene: CanvasScene,
            selection: Set<CanvasElementID>,
            configuration: MotionConfiguration,
            images: any ImageProvider,
            retryPolicy: ImageRetryPolicy = .default,
            commands: CanvasCommandRelay,
            onSceneChange: @escaping (CanvasScene) -> Void,
            onSelectionChange: @escaping (Set<CanvasElementID>) -> Void,
            onCameraChange: @escaping (CanvasCamera) -> Void,
            // 这两个有默认值：性能报告与自检里那些"只想量一次提交"的协调器
            // 不接界面，给它们各写一遍空闭包只会淹没真正的参数。
            onDrop: @escaping (ClipboardPayload, CGPoint) -> Bool = { _, _ in false },
            onPaste: @escaping () -> Void = {}
        ) {
            self.scene = scene
            self.selection = selection
            self.renderer = LayerRenderer(
                camera: camera,
                configuration: configuration,
                images: images,
                retryPolicy: retryPolicy
            )
            // 起点是"同一块画布的空场景"：这样首次 `syncScene()` 会把已有元素
            // 全部判为 inserted，非空初始场景也能一次画出来。
            self.syncedScene = CanvasScene(boardID: scene.boardID)
            self.commands = commands
            self.motionConfiguration = configuration
            self.onSceneChange = onSceneChange
            self.onSelectionChange = onSelectionChange
            self.onCameraChange = onCameraChange
            self.onDrop = onDrop
            self.onPaste = onPaste
            self.reportedCamera = camera
            renderer.setMotionConfiguration(configuration)
        }

        func attach(to view: CanvasHostNSView) {
            self.view = view
            // 输入层要在渲染器之前拿到 context：`attach` 里可能补一次全量同步，
            // 那时覆盖层要根据选择重算一次，输入层得已经能读到场景。
            input.attach(to: self)
            renderer.attach(to: view.layer ?? CALayer())
            renderer.setBackingScaleFactor(view.window?.backingScaleFactor ?? 2)
            connectCommands()
            // 挂载时补一次全量同步。协调器可能带着非空场景诞生（恢复的画布、
            // 或 SwiftUI 在 makeNSView 之前就先放了元素），那批元素必须在这里
            // 补上——`updateNSView` 只在场景**变化**时才有效。
            syncScene()
        }

        /// 把工具栏的命令接到输入适配器上。
        ///
        /// 工具栏按钮与触控板手势必须走同一条路径——同样的锚点规则、同样的缓动、
        /// 同样可被直接输入打断。绕开适配器直接改相机，就会出现「按钮缩放没有
        /// 动画」这类不一致，而且批次 B 换掉输入实现时它会变成漏网之鱼。
        private func connectCommands() {
            commands.zoomStep = { [weak self] factor in
                guard let self else { return }
                input.zoomStep(factor, context: self)
            }
            commands.zoomTo = { [weak self] zoom in
                guard let self else { return }
                input.zoomTo(zoom, context: self)
            }
            commands.focusContent = { [weak self] in
                guard let self else { return }
                input.focus(on: scene.contentBounds, context: self)
            }
            commands.focusSelection = { [weak self] in
                self?.focusSelection()
            }
            commands.reloadAsset = { [weak self] asset in
                self?.renderer.reload(asset: asset)
            }
        }

        func setTool(_ tool: CanvasTool) {
            input.setTool(tool, context: self)
        }

        func focusSelection() {
            let bounds = scene.elements
                .filter { selection.contains($0.id) }
                .reduce(CGRect.null) { $0.union($1.frame) }
            guard !bounds.isNull else { return }
            input.focus(on: bounds, context: self)
        }

        func requestRedraw() {
            view?.needsDisplay = true
        }

        /// 输入层给的是语义值，`NSCursor` 是这里的事。
        ///
        /// 去重放在宿主而不是输入层：光标是**窗口级**状态，指针离开视图时
        /// 由 `CanvasHostNSView.mouseExited` 直接恢复成箭头（那一刻输入层
        /// 什么都不知道），所以缓存必须和"谁真正设的光标"放在一起。
        func setCursor(_ cursor: CanvasCursor) {
            guard cursor != lastCursor else { return }
            lastCursor = cursor
            cursor.nsCursor.set()
        }

        private var lastCursor: CanvasCursor = .arrow

        /// 指针离开画布时调用。恢复箭头并清缓存，让下次进入时能重新设一次。
        func resetCursorOnExit() {
            lastCursor = .arrow
            NSCursor.arrow.set()
        }

        /// 视图外观变化（深浅色切换）。覆盖层的颜色是写进 CALayer 的静态
        /// `CGColor`，不会自己跟着变——不刷新的话，深色模式下的选择框还是
        /// 浅色那一版，几乎看不见。
        func viewAppearanceChanged() {
            renderer.appearance = view?.effectiveAppearance ?? NSAppearance.currentDrawing()
        }

        func setMotionConfiguration(_ configuration: MotionConfiguration) {
            guard configuration != motionConfiguration else { return }
            motionConfiguration = configuration
            renderer.setMotionConfiguration(configuration)
        }

        /// SwiftUI 侧改动的相机。只在确实不同时才应用，避免与直接操控打架。
        func applyExternalCamera(_ camera: CanvasCamera) {
            guard camera != renderer.camera, camera != reportedCamera else { return }
            renderer.apply(CanvasRenderUpdate(camera: camera))
            reportedCamera = camera
            requestRedraw()
        }

        /// SwiftUI 侧改动过的场景。
        ///
        /// 用整值比较而不是只比 `revision`：新建场景的 revision 从 0 重新开始，
        /// 换画布时可能与旧场景撞号，那时只比 revision 就会漏掉一次全量重建。
        /// 元素数量在 O(10²) 量级，整值比较的开销可以忽略。
        func applyExternalScene(_ scene: CanvasScene) {
            guard scene != self.scene else { return }
            let boardChanged = scene.boardID != self.scene.boardID
            self.scene = scene
            if boardChanged {
                discardOverlay()
                // 换画布时清空撤销栈。
                //
                // 栈里那几条记的是**另一块画布**上的元素 ID 与外框。留着的话，
                // ⌘Z 会把改动应用到看不见的地方——用户看到的只是"撤销没反应"，
                // 而重做栈里躺着的那份状态已经和当前画布无关了。
                undoManager?.removeAllActions()
            }
            syncScene()
        }

        /// 换画布时丢掉覆盖层。
        ///
        /// 覆盖层描述的是**当前显示的这块画布**上的东西：选择框用世界坐标给，
        /// 换一块画布之后同一组坐标指的是完全不同的位置；对齐辅助线更是只在
        /// 那一次拖拽期间有意义，留着会画出一条没有来由的线。
        ///
        /// **丢掉而不是按画布存。** 覆盖层是瞬态渲染输入，不是状态——它每帧都由
        /// 输入层按当时的选择和拖拽现场重算。按画布存的话，切回来会先显示一份
        /// 过期的辅助线，而正确的内容要等下一次输入才出现。换回来后重新提交
        /// 覆盖层是输入层（Codex 的 `SelectionController`）的职责。
        ///
        /// 这条和选择必须成对：选择按画布分开之后，覆盖层如果还是宿主全局的，
        /// 就等于"选中的是这块画布，画出来的是上一块画布的框"。
        private func discardOverlay() {
            // 不回报：覆盖层没有上行通道，`overlay` 的 didSet 只喂渲染器，
            // 而本函数是在 `updateNSView` 里被调用的——那里不能碰 SwiftUI 状态。
            overlay = .empty
        }

        /// 把 `scene` 相对 `syncedScene` 的差异送进渲染器。
        ///
        /// **这是场景到渲染器的唯一通路。** 第一版这里只送了 `order` 和相机，
        /// 没有送 `inserted`/`updated`/`removed`，结果是 SwiftUI 拿到了新场景、
        /// 渲染器却永远收不到元素——批次 B 往画布放第一个元素时才会暴露。
        private func syncScene() {
            let change = scene.change(from: syncedScene)
            guard !change.isEmpty else { return }
            syncedScene = scene
            renderer.apply(CanvasRenderUpdate(change: change))
            requestRedraw()
        }

        /// 视口尺寸变化。相机的 `viewportSize` 必须跟着变，否则命中与显示会错位。
        func updateViewport(size: CGSize, backingScaleFactor: CGFloat) {
            guard size.width > 0, size.height > 0 else { return }
            renderer.setBackingScaleFactor(backingScaleFactor)
            var camera = renderer.camera
            guard camera.viewportSize != size else { return }
            camera.viewportSize = size
            renderer.camera = camera
            renderer.updateLayerFrames(for: size)
            reportedCamera = camera
            onCameraChange(camera)
            requestRedraw()
        }

        // MARK: - 事件翻译与转发
        //
        // 这里是 `NSEvent → 值对象` 的边界。往下（`CanvasInputAdapter`）不再出现
        // AppKit 类型，所以交互逻辑可以在自检里构造输入直接断言。

        func scrollWheel(_ event: NSEvent) {
            guard let view else { return }
            input.scrollWheel(
                CanvasEventTranslation.scroll(event, in: view, camera: renderer.camera),
                context: self
            )
            view.needsDisplay = true
        }

        func magnify(_ event: NSEvent) {
            guard let view else { return }
            input.magnify(
                CanvasEventTranslation.magnify(event, in: view, camera: renderer.camera),
                context: self
            )
            view.needsDisplay = true
        }

        func pointerDown(_ event: NSEvent, button: CanvasPointerButton) {
            guard let view else { return }
            let pointer = CanvasEventTranslation.pointer(
                event, in: view, camera: renderer.camera, button: button
            )
            switch button {
            case .left, .other:
                // 中键和左键走**同一条**入口：是不是平移由输入层按按键决定，
                // 宿主不替它判断。右键才是另一回事（上下文菜单）。
                input.pointerDown(pointer, context: self)
            case .right:
                input.secondaryPointerDown(pointer, context: self)
            }
            view.needsDisplay = true
        }

        func pointerDragged(_ event: NSEvent, button: CanvasPointerButton) {
            guard let view else { return }
            guard button != .right else { return }
            input.pointerDragged(
                CanvasEventTranslation.pointer(
                    event, in: view, camera: renderer.camera, button: button
                ),
                context: self
            )
            view.needsDisplay = true
        }

        func pointerUp(_ event: NSEvent, button: CanvasPointerButton) {
            guard let view else { return }
            guard button != .right else { return }
            input.pointerUp(
                CanvasEventTranslation.pointer(
                    event, in: view, camera: renderer.camera, button: button
                ),
                context: self
            )
            view.needsDisplay = true
        }

        func pointerMoved(_ event: NSEvent) {
            guard let view else { return }
            input.pointerMoved(
                CanvasEventTranslation.pointer(
                    event, in: view, camera: renderer.camera, button: .left
                ),
                context: self
            )
        }

        /// 返回 `false` 表示未消费，宿主按常规向上传递。
        func keyDown(_ event: NSEvent) -> Bool {
            input.keyDown(CanvasEventTranslation.key(event), context: self)
        }

        /// 空格平移靠它退出——见 `CanvasInputAdapter.keyUp` 的说明。
        func keyUp(_ event: NSEvent) {
            input.keyUp(CanvasEventTranslation.key(event), context: self)
        }

        // MARK: 菜单命令的落点（由 CanvasHostNSView 的响应链入口转发过来）

        /// 「全选」。走的是和键盘完全相同的那条路。
        @discardableResult
        func selectAll() -> Bool {
            input.keyDown(
                CanvasKeyInput(characters: "a", keyCode: 0, modifiers: [.command], isARepeat: false),
                context: self
            )
        }

        /// 上下文菜单的删除也必须进入 `SelectionController`：那里才会登记与
        /// 键盘 Delete 相同的逆操作，避免右键删除成为唯一不能 ⌘Z 的路径。
        @discardableResult
        func deleteElement(_ id: CanvasElementID) -> Bool {
            input.selectionController.deleteElement(id, context: self)
        }

        /// 撤销 / 重做。
        ///
        /// 撤销栈是**窗口的** `UndoManager`（`⌘Z` 的常规路径），这里只是转发 +
        /// 让覆盖层跟着重算一遍：撤销改的是外框，而覆盖层是按外框画出来的，
        /// 不重算的话框会停在原地，图却已经回去了。
        func undo() {
            undoManager?.undo()
            input.selectionDidChange(context: self)
            requestRedraw()
        }

        func redo() {
            undoManager?.redo()
            input.selectionDidChange(context: self)
            requestRedraw()
        }

        // MARK: - 拖入与粘贴（§4 第 1、2 条）

        /// 一批东西落在画布上。
        ///
        /// 视图坐标 → 世界坐标的换算在这里做，因为**只有这里同时知道相机和
        /// 视图**。落到 `GridPlacement` 的必须是世界坐标：给视图点的话，
        /// 缩放 50% 时用户把图放在光标下，图会出现在两倍远的地方。
        ///
        /// - Returns: 收不收。空的不收——返回 `true` 的话系统会播放下落动画，
        ///   而画布上什么都不会出现，那比明确拒收更让人困惑。
        func drop(_ payload: ClipboardPayload, atViewPoint viewPoint: CGPoint) -> Bool {
            guard !payload.isEmpty else { return false }
            return onDrop(payload, camera.viewToWorld(viewPoint))
        }

        /// ⌘V。剪贴板读什么、怎么入库都不在这里——画布只负责"用户在这儿按的"。
        func paste() {
            onPaste()
        }

        func flagsChanged(_ event: NSEvent) {
            input.flagsChanged(CanvasModifiers(event.modifierFlags), context: self)
        }

        // MARK: - 自检探针
        //
        // 「场景 → 渲染器 → 图层」闭环的证据必须取自上一步真正发生的地方。
        // 这几个入口只服务 `--selftest`，不属于任何协议。

        /// 渲染器里实际的子层顺序（由下到上）。
        var renderedElementOrder: [CanvasElementID] { renderer.sublayerIDsInDrawOrder }

        /// 渲染器里某个元素图层的实际外框。
        func renderedFrame(of id: CanvasElementID) -> CGRect? { renderer.sublayerFrame(of: id) }

        /// 当前**真的有图层**的元素集合。取自真实图层树（`renderedElementOrder`），
        /// 不是渲染器的字典——虚拟化的断言要的就是"屏幕上到底建了几个图层"。
        var renderedElementIDs: Set<CanvasElementID> { Set(renderer.sublayerIDsInDrawOrder) }

        /// 建了图层的元素个数。虚拟化的效果本身就是这个数字（B2 报告要读）。
        var materializedElementCount: Int { renderer.materializedElementCount }

        /// 渲染器算出的可见世界矩形（含预加载边距）。断言用它跟**自己算的**矩形对，
        /// 两边一致才说明"可见"的判据没有第二份。
        var renderedVisibleWorldRect: CGRect { renderer.visibleWorldRect }

        /// 渲染器最近收到的覆盖层。
        var renderedOverlay: CanvasOverlay { renderer.lastOverlay }

        /// 画布上**真的画出来**了几个选中框。读的是 `CAShapeLayer.path`。
        var renderedSelectionBorderCount: Int { renderer.renderedSelectionBorderCount }

        /// 手柄路径里真的有几个月牙方块。多选或没选中时必须是 0。
        var renderedHandleCount: Int { renderer.renderedHandleCount }

        /// 框选矩形现在画没画。
        var renderedMarqueeVisible: Bool { renderer.renderedMarqueeVisible }

        /// 选中框在视图坐标里的位置（读的是真实路径）。
        var renderedSelectionBorderBounds: CGRect { renderer.renderedSelectionBorderBounds }

        /// 某个元素图层里实际的像素尺寸。读的是 `layer.contents`，
        /// 不是渲染器的记账——否则断言是自证。
        func renderedImageSize(of id: CanvasElementID) -> CGSize? {
            renderer.sublayerImageSize(of: id)
        }

        /// 某个元素图层里**真的有**的像素是哪一档。像素还没到就是 `nil`。
        func renderedTier(of id: CanvasElementID) -> LODTier? { renderer.sublayerTier(of: id) }

        /// 某个元素正在要（在飞）或已经显示的那一档。断言问"请求发出去了吗"用它。
        func requestedTier(of id: CanvasElementID) -> LODTier? { renderer.requestedTier(of: id) }

        /// 这个元素还在等像素（在飞或等重试）。
        func isAwaitingImage(_ id: CanvasElementID) -> Bool { renderer.isAwaitingImage(id) }

        /// 这个元素的图层现在铺的是失败底色吗（用户看到的那个信号）。
        func showsFailurePlaceholder(_ id: CanvasElementID) -> Bool {
            renderer.sublayerShowsFailurePlaceholder(of: id)
        }

        /// 这个元素图层现在还有没有底色（占位色与失败色都算）。
        /// 真图到位之后它必须是 `false`——透明区域前不许垫东西。
        func hasBackingColor(_ id: CanvasElementID) -> Bool {
            renderer.sublayerHasBackingColor(of: id)
        }

        /// 取不到像素的元素及原因。
        var renderedImageFailures: [CanvasElementID: String] { renderer.imageFailures }

        /// 取不到像素、且元素还在场景里的那些。界面靠它决定显不显示"重新加载"。
        var renderedFailedImageIDs: Set<CanvasElementID> { renderer.failedImageIDs }

        /// 手动重新加载某个元素的图片。元素级的重试入口。
        func retryImage(for id: CanvasElementID) { renderer.retryImage(for: id) }

        /// 手动重新加载全部失败的图片。返回重试了几个。
        @discardableResult
        func retryAllFailedImages() -> Int { renderer.retryAllFailedImages() }

        /// 走一次完整的「外部场景 → 渲染器」路径。自检用它验证 `updateNSView` 那条路。
        func applySceneFromOutside(_ scene: CanvasScene) { applyExternalScene(scene) }

        // MARK: 自检探针（输入）
        //
        // 直接交**值对象**给输入适配器，跳过 `NSEvent → 值对象` 那一层
        // （那一层的正确性归 `CanvasEventTranslation`）。这样手感参数可以在自检里
        // 构造输入直接断言——`CanvasInputAdapter` 的协议注释一直承诺"交互逻辑
        // 可以在测试里构造输入直接断言"，但没有入口时那句话是空头支票。
        //
        // 走的是翻译之后**完全相同**的那条路：宿主在真实事件里也只是把值对象
        // 转交给同一个适配器。所以这里验的不是另一套代码。

        /// 世界层是否裁剪。裁它会让跨越视口边界的元素整块消失，所以它必须是 false。
        var worldLayerMasksToBounds: Bool { renderer.worldLayer.masksToBounds }

        /// 交一次滚动。返回处理后的相机，省得调用点再取一次。
        @discardableResult
        func handleScroll(_ event: CanvasScrollInput) -> CanvasCamera {
            input.scrollWheel(event, context: self)
            return renderer.camera
        }

        @discardableResult
        func handleMagnify(_ event: CanvasMagnifyInput) -> CanvasCamera {
            input.magnify(event, context: self)
            return renderer.camera
        }

        /// 按倍数步进缩放（工具条按钮与 `⌘=` / `⌘-` 走的就是这一条）。
        ///
        /// 默认会走缓动，所以调用方通常要把 `programmaticCameraDuration` 设成 0
        /// 才能同步断言终态——那是刻意保留的能力：`reduceMotion` 与"时长为 0"
        /// 两条路本来就要求直接跳到终态。
        @discardableResult
        func handleZoomStep(_ factor: CGFloat) -> CanvasCamera {
            input.zoomStep(factor, context: self)
            return renderer.camera
        }

        /// 交一次捏合。
        @discardableResult
        func handleFocus(on worldRect: CGRect) -> CanvasCamera {
            input.focus(on: worldRect, context: self)
            return renderer.camera
        }

        // MARK: 自检探针（选择与直接操控）
        //
        // 与上面那组同理：交值对象给同一个适配器，走的是和真实事件完全相同的
        // 那条路。断言因此能覆盖"点中谁、拖到哪、撤销退到哪"，而不必真的动鼠标。

        @discardableResult
        func handlePointerDown(_ input: CanvasPointerInput) -> CanvasCamera {
            pointer(input, .down)
            return renderer.camera
        }

        func handlePointerDragged(_ input: CanvasPointerInput) {
            pointer(input, .dragged)
        }

        func handlePointerUp(_ input: CanvasPointerInput) {
            pointer(input, .up)
        }

        /// 交一次**未按键的悬停**。光标反馈走这一条。
        func handlePointerMoved(_ input: CanvasPointerInput) {
            self.input.pointerMoved(input, context: self)
        }

        @discardableResult
        func handleKeyDown(_ input: CanvasKeyInput) -> Bool {
            self.input.keyDown(input, context: self)
        }

        func handleKeyUp(_ input: CanvasKeyInput) {
            self.input.keyUp(input, context: self)
        }

        private func pointer(_ input: CanvasPointerInput, _ phase: PointerPhase) {
            switch phase {
            case .down: self.input.pointerDown(input, context: self)
            case .dragged: self.input.pointerDragged(input, context: self)
            case .up: self.input.pointerUp(input, context: self)
            }
        }

        private enum PointerPhase { case down, dragged, up }

        /// 最近一次设上去的光标。断言用它验证手柄反馈。
        var currentCursor: CanvasCursor { lastCursor }

        /// 现在是不是在拖动画布。
        var isPanningCanvas: Bool { input.isPanning }

        /// 待平移状态（空格按住）。
        var isSpacePanReady: Bool { input.isSpacePanReady }

        /// 有没有缓动在播。断言用它验证"直接操控打断程序动画"。
        var isAnimatingCamera: Bool { input.isAnimatingCamera }

        /// 正在缩放元素（不是拖动、不是平移）。
        var isResizingElement: Bool { input.selectionController.isResizingElement }

        /// 正在拖动元素。
        var isMovingElements: Bool { input.selectionController.isDirectManipulating }
    }
}

/// 画布在响应链上对外承诺的动作。
///
/// ## 为什么要把选择器收成一处
///
/// 菜单（SwiftUI 的 `Commands`）和画布（`CanvasHostNSView`）是**两处独立写的
/// 代码**，它们之间唯一的接头就是这个选择器字符串。写歪一个字符的话，两边都还
/// 在、编译也过、自检也绿，只是菜单发出去的那一下**落到空处**——撤销点不动、
/// 快捷键也没反应，而且没有任何报错。
///
/// 这不是假设：这里原先菜单发的是无冒号的 `undo`（那是 `UndoManager` 自己的
/// 方法，而 `UndoManager` **不在响应链上**）。画布上那条路一直是对的，
/// 只是没人走到它。
///
/// 收成一处之后，"两边写得不一致"这个可能就从根上没有了。剩下的那一半
/// ——"这个选择器到底能不能被画布接住、接住之后真的会撤销吗"——由自检走
/// **真窗口的响应链**问一遍（`SelfTest.responderChainActionsAreWired`）。
enum CanvasResponderAction {

    /// 带冒号的 `undo:`。
    ///
    /// **冒号是有意义的**：它表示"带一个 sender 参数"，与无参的
    /// `UndoManager.undo` 是两个不同的选择器。选错那个的代价是静默的。
    static let undo = #selector(CanvasHostNSView.undo(_:))

    static let redo = #selector(CanvasHostNSView.redo(_:))
}

/// AppKit 画布表面。
///
/// 只做三件事：转发输入、绘制背景网格、把尺寸变化告诉协调器。
/// 所有画布状态都在协调器与渲染器里，视图本身不持有相机。
final class CanvasHostNSView: NSView, NSMenuItemValidation {
    /// 右键命中的元素。菜单 action 在下一轮事件循环执行，不能届时再按当前
    /// 鼠标位置命中，否则用户稍微移动鼠标就会删错对象。
    private var contextMenuElementID: CanvasElementID?
    var undoConfiguration: CanvasUndoConfiguration = .default
    var canEditSVG: ((CanvasElementID) -> Bool)?
    var onEditSVG: ((CanvasElementID) -> Void)?
    weak var context: CanvasHostView.Coordinator?

    var showsGrid = true {
        didSet { if showsGrid != oldValue { needsDisplay = true } }
    }

    /// 原点在左上、y 向下，与 `CanvasCamera` 的约定一致。
    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    private var hoverTrackingArea: NSTrackingArea?

    override func makeBackingLayer() -> CALayer {
        CALayer()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // 拖入落点（§4 第 1 条）。第一版只登记 `.fileURL`，理由是"位图那条路和
        // 粘贴是同一件事"。现在不成立了：**网页里的图拖出来是位图数据，没有
        // 原文件**（见 `ClipboardPayload`），而它走的是拖入这条手势，不是粘贴。
        // 不登记这些类型的表现是拖拽进来光标一直是禁止符，`draggingEntered`
        // 根本不会被调用——连失败都记不下来。
        registerForDraggedTypes(Array(Self.acceptedDragTypes))
        // ## 这一行是必须的，不是优化
        //
        // `CALayer` 默认**不裁剪子层**，而画布是 `HStack` 里靠右的一个兄弟视图：
        // 世界坐标下超出视口的元素照样被合成，于是**画到左侧素材面板上去了**。
        // 用户实测发现的：四列素材在 100% 缩放下比视口宽，最左一列压在面板的
        // 空状态文案上，看起来像"面板没渲染"，实际是画布越界。
        //
        // ## 为什么写在这里，不写进 `makeBackingLayer`
        //
        // 第一版就是写在 `makeBackingLayer` 里的，**没有生效**：AppKit 在拿到
        // backing layer 之后会把 `masksToBounds` 重置为 `false`
        // （实测：`makeBackingLayer` 里设 `true`，`init` 结束时读回来是 `false`）。
        // 必须在 `wantsLayer = true` **之后**设。自检里那条断言就是钉这个的
        // ——把这一行挪回 `makeBackingLayer` 会被它抓住。
        //
        // ## 为什么裁这一层而不是 `worldLayer`
        //
        // `worldLayer` 带着相机变换，给它加蒙版等于**在世界坐标里裁**
        // （裁的是元素自己的 bounds），会把"元素有一部分在视口外"变成
        // "整个元素不画"。视口这一层才是正确的裁剪位置，语义是「画布之外不画」。
        //
        // 它**不是**视口虚拟化：越界的图层仍然存在、仍然占用内存，只是不被合成。
        // "不为不可见元素花代价"属于 B2。
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override func layout() {
        super.layout()
        context?.updateViewport(
            size: bounds.size,
            backingScaleFactor: window?.backingScaleFactor ?? 2
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // AppKit 的默认值 0 代表无限历史。把容量写进窗口实际使用的
        // UndoManager，`⌘Z`、菜单和画布手势才会遵循同一条 15 步上限。
        window?.undoManager?.levelsOfUndo = undoConfiguration.maximumSteps
        context?.updateViewport(
            size: bounds.size,
            backingScaleFactor: window?.backingScaleFactor ?? 2
        )
        window?.makeFirstResponder(self)
    }

    /// 悬停事件需要显式声明追踪区域，AppKit 不会平白投递 `mouseMoved`。
    /// `.inVisibleRect` 让 AppKit 自己跟着尺寸走，不必在 `layout()` 里重设。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    // MARK: - 输入转发
    //
    // 视图只负责转发，不解释事件——翻译在 Coordinator，解释在 CanvasInputAdapter。
    // 这样 Codex 替换输入实现时不必碰这个文件（路线图 §4 规则 3）。

    override func scrollWheel(with event: NSEvent) {
        context?.scrollWheel(event)
    }

    override func magnify(with event: NSEvent) {
        context?.magnify(event)
    }

    override func mouseDown(with event: NSEvent) {
        // 双击 SVG 是 Figma 式「钻进内部结构」的入口：画布保持选择模型不变，
        // 具体的 `<g>` 钻取在编辑窗口内进行（那里才拥有 SVG DOM）。
        if event.clickCount == 2, let context {
            let viewPoint = convert(event.locationInWindow, from: nil)
            if let id = context.hitTest(worldPoint: context.camera.viewToWorld(viewPoint)),
               canEditSVG?(id) == true {
                onEditSVG?(id)
                return
            }
        }
        context?.pointerDown(event, button: .left)
    }

    override func mouseDragged(with event: NSEvent) {
        context?.pointerDragged(event, button: .left)
    }

    override func mouseUp(with event: NSEvent) {
        context?.pointerUp(event, button: .left)
    }

    override func mouseMoved(with event: NSEvent) {
        context?.pointerMoved(event)
    }

    /// 指针离开画布：光标恢复成箭头。
    ///
    /// 在这里做而不是在输入层：离开视图不是一种"输入"，输入层收不到它，
    /// 但它必须让光标恢复正常——否则指针移到素材面板上还顶着一个张开的手。
    override func mouseExited(with event: NSEvent) {
        context?.resetCursorOnExit()
    }

    /// 右键。**画布现在不做右键手势**（`pointerDown(button: .right)` 落到
    /// `InputController` 的空分支），所以这一条专门的输入交给上下文菜单。
    ///
    /// 走 `super` 而不是自己弹菜单：`NSView` 的默认实现会取 `menu(for:)` 的结果
    /// 并把它弹出来，自己再写一遍 `NSMenu.popUpContextMenu` 等于两处都能决定
    /// "有没有菜单"。
    ///
    /// **将来要右键手势时**（比如右键拖动平移），得先按路线图 §4 规则 4 提接口
    /// 提案：手势一旦消费右键，菜单就得挪到别的键或别的触发方式上，那是个产品
    /// 决定，不该在这里悄悄发生。
    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
    }

    /// 画布右键菜单。
    ///
    /// 现在只有一项「粘贴图片」。**不顺手加撤销/全选**：那些在菜单栏里都有、
    /// 且各自有快捷键，右键菜单重复一遍只会让"这里该有什么"变得没有标准。
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let context {
            contextMenuElementID = context.hitTest(worldPoint: context.camera.viewToWorld(viewPoint))
            if let id = contextMenuElementID {
                if canEditSVG?(id) == true {
                let edit = NSMenuItem(title: "编辑 SVG", action: #selector(editContextSVG(_:)), keyEquivalent: "")
                edit.target = self
                menu.addItem(edit)
                }
                let delete = NSMenuItem(title: "删除", action: #selector(deleteContextElement(_:)), keyEquivalent: "")
                delete.target = self
                menu.addItem(delete)
                menu.addItem(.separator())
            }
        }
        let paste = NSMenuItem(
            title: "粘贴图片", action: #selector(paste(_:)), keyEquivalent: ""
        )
        // 显式指定 target，不靠响应链：右键**不会**把第一响应者改到画布上
        // （用户可能刚在地址栏里打过字），靠响应链找的话这一项在那种时候是灰的。
        paste.target = self
        menu.addItem(paste)
        return menu
    }

    @objc private func deleteContextElement(_: Any?) {
        guard let id = contextMenuElementID, let context else { return }
        _ = context.deleteElement(id)
        contextMenuElementID = nil
    }

    @objc private func editContextSVG(_: Any?) {
        guard let id = contextMenuElementID, canEditSVG?(id) == true else { return }
        onEditSVG?(id)
    }

    override func rightMouseDragged(with event: NSEvent) {
        context?.pointerDragged(event, button: .right)
    }

    override func rightMouseUp(with event: NSEvent) {
        context?.pointerUp(event, button: .right)
    }

    override func otherMouseDown(with event: NSEvent) {
        context?.pointerDown(event, button: .other)
    }

    override func otherMouseDragged(with event: NSEvent) {
        context?.pointerDragged(event, button: .other)
    }

    override func otherMouseUp(with event: NSEvent) {
        context?.pointerUp(event, button: .other)
    }

    override func keyDown(with event: NSEvent) {
        // 未消费的按键交回系统：macOS 的默认反馈是响一声，这比默默吞掉更容易
        // 发现"快捷键没接上"。Command 组合键走菜单的 performKeyEquivalent，
        // 不经过这里。
        guard let context, context.keyDown(event) else {
            super.keyDown(with: event)
            return
        }
    }

    /// 键盘松开。**空格平移必须靠它退出**，不能省。
    override func keyUp(with event: NSEvent) {
        context?.keyUp(event)
    }

    override func flagsChanged(with event: NSEvent) {
        context?.flagsChanged(event)
    }

    /// 深浅色切换。覆盖层颜色是写进 CALayer 的静态 `CGColor`，宿主得显式刷新。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        context?.viewAppearanceChanged()
    }

    // MARK: - 响应链入口（菜单命令）
    //
    // 菜单项在 `PinNativeApp` 里用 `target: nil` 挂上，AppKit 沿响应链找到
    // 第一响应者。画布是绘制区域的常规第一响应者，所以这几个方法要落在
    // **视图**上——协调器不在响应链里。

    /// `selectAll:` 是 `NSResponder` 已有的方法，所以要 `override`——
    /// 这也正是它值得挂在这里的原因：⌘A 的默认路径本来就沿响应链找它。
    override func selectAll(_ sender: Any?) {
        context?.selectAll()
    }

    /// `paste:` 走的也是**标准选择器**（和 `selectAll:` 同一个道理）。
    ///
    /// 用标准选择器而不是自定义的，是为了让搜索框里的 ⌘V 仍然是"粘贴文字"：
    /// 文本视图在响应链上离第一响应者更近，它先接住，根本轮不到这里。
    /// 定义成自定义选择器再挂菜单快捷键的话，菜单会在响应链之前把 ⌘V 抢走，
    /// 表现就是"在搜索框里按 ⌘V 粘出来一张图"。
    @objc func paste(_ sender: Any?) {
        context?.paste()
    }

    @objc func undo(_ sender: Any?) {
        context?.undo()
    }

    @objc func redo(_ sender: Any?) {
        context?.redo()
    }

    /// 菜单项的可用状态（变灰还是可点）。
    ///
    /// 走 `NSMenuItemValidation` 而不是 `NSResponder` 的重载：`NSView` 没有
    /// `validateMenuItem`，AppKit 是通过这个协议在响应链上问的——
    /// 写成 `override` 编译不过（第一版就是那么写的）。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): return context?.undoManager?.canUndo ?? false
        case #selector(redo(_:)): return context?.undoManager?.canRedo ?? false
        case #selector(selectAll(_:)): return !(context?.scene.isEmpty ?? true)
        case #selector(paste(_:)): return Self.pasteboardHasImportableContent
        default: return true
        }
    }

    /// 剪贴板里有没有我们能收的东西。**只读类型，不读数据**——
    /// 菜单每次打开都会问一遍，读整张位图（可能是几十 MB）只为决定一个
    /// 菜单项的灰与不灰，代价完全不成比例。
    ///
    /// 文案上"能粘"和"粘成功"是两件事：这里说有，粘下去仍可能因为尺寸超限
    /// 被拒——那时提示胶囊会说原因。宁可这样，也不要让菜单项在"其实能粘"
    /// 的时候是灰的。
    private static var pasteboardHasImportableContent: Bool {
        let pasteboard = NSPasteboard.general
        return pasteboard.canReadObject(forClasses: [NSURL.self])
            || pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    // MARK: - 拖入落点（§4 第 1 条）
    //
    // ## 为什么拖入接在 NSView 上，而不是 SwiftUI 的 `.dropDestination`
    //
    // 画布是 `NSViewRepresentable`，SwiftUI 的落点是加在**外层容器**上的：
    // 事件会先到容器，落点坐标是容器的坐标，还得再换算回画布视图坐标——
    // 多一次转换就多一个"差一个面板宽度"的机会。而 AppKit 这边本来就已经在
    // 收鼠标事件了，`draggingLocation` 直接就是画布视图坐标。
    //
    // 素材面板那边是纯 SwiftUI，用的就是 `.dropDestination`（见 `MaterialPanel`）。

    /// 拖动进入。返回的操作符决定光标上挂什么徽标：`.copy` 是加号。
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragLooksImportable(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // 每一帧都重算：拖动途中经过别的 App，剪贴板内容会变。
        dragLooksImportable(sender) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dragLooksImportable(sender)
    }

    /// 松手。
    ///
    /// ## 剪贴板必须在这里**同步**读完
    ///
    /// `draggingPasteboard` 只在这一次拖放会话里有效。交给异步的导入流水线
    /// （`Task { }` 在下一个主 actor 回合才跑）就等于去读一块已经被拆掉的板子，
    /// 读出来是空——而失败表现是"拖进去什么都没发生"，非常难查。
    ///
    /// 读出来的 `ClipboardPayload` 里装的是 `Data`（值类型），带过这个边界是
    /// 安全的，所以这里读完就把值交出去，不做任何耗时的事。
    ///
    /// ## 为什么不当场导入
    ///
    /// 这个方法必须立刻回答收不收，而导入是异步的。返回 `true` 只说"我接下了"，
    /// 成败由提示胶囊事后汇报——失败也绝不会静默。
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let payload = PasteboardReader(pasteboard: sender.draggingPasteboard).read()
        guard !payload.isEmpty else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        return context?.drop(payload, atViewPoint: point) ?? false
    }

    /// 这次拖拽里有没有我们收得下的东西。
    ///
    /// ## 只看类型，不读数据
    ///
    /// `draggingUpdated` 每一帧都会问一遍，而读数据要解码整张位图（网页上拖
    /// 一张大图就是几十 MB）——只为决定光标上挂不挂那个加号徽标，代价完全
    /// 不成比例。真正的读发生在 `performDragOperation`，那一次是必要的。
    ///
    /// ## 为什么要列这么多类型
    ///
    /// `registerForDraggedTypes` 按类型名**精确匹配**，不做协议一致性推导，
    /// 所以列在下面的是"能不能收到这个拖拽"的全部依据。网页拖出来的图宣告的
    /// 是 `public.png` / `public.jpeg` / `public.tiff`，访达给的是
    /// `public.file-url`——这几类都在。
    private func dragLooksImportable(_ sender: any NSDraggingInfo) -> Bool {
        let types = sender.draggingPasteboard.types ?? []
        return !Set(types).isDisjoint(with: Self.acceptedDragTypes)
    }

    /// 内部可见（不是 `private`）：自检拿真实的 WebKit 拖拽类型清单来钉它——
    /// 这个集合被削掉一项，网页拖拽那条通道就静默消失，而界面不会报任何错。
    static let acceptedDragTypes = PasteboardReader.acceptedDragTypes

    // MARK: - 背景网格
    //
    // 批次 A 的网格画在 `draw(_:)` 里，不是图层内容：网格是无限延伸的背景，
    // 每次相机变化都要按新的间距重画，放进图层树反而不划算。
    //
    // 元素图层走 LayerRenderer 的 worldLayer（路线图 §2.1）。批次 B 接入元素后，
    // 由实测决定网格是否需要移进图层树——§2.4 要求在测得数字之后再优化，
    // 而不是先假定它是瓶颈。

    override func draw(_ dirtyRect: NSRect) {
        guard let context else { return }
        let camera = context.camera
        let palette = CanvasPalette.current

        palette.background.setFill()
        dirtyRect.fill()

        guard showsGrid else { return }

        let step = Self.gridStep(forZoom: camera.zoom)
        guard step > 0 else { return }

        let visible = camera.visibleWorldRect()
        let path = NSBezierPath()
        path.lineWidth = 1

        let startX = (visible.minX / step).rounded(.down) * step
        var x = startX
        while x <= visible.maxX {
            let viewX = camera.worldToView(CGPoint(x: x, y: 0)).x.rounded() + 0.5
            path.move(to: CGPoint(x: viewX, y: 0))
            path.line(to: CGPoint(x: viewX, y: bounds.height))
            x += step
        }

        let startY = (visible.minY / step).rounded(.down) * step
        var y = startY
        while y <= visible.maxY {
            let viewY = camera.worldToView(CGPoint(x: 0, y: y)).y.rounded() + 0.5
            path.move(to: CGPoint(x: 0, y: viewY))
            path.line(to: CGPoint(x: bounds.width, y: viewY))
            y += step
        }

        palette.gridLine.setStroke()
        path.stroke()

        drawOriginMark(camera: camera, palette: palette)
    }

    /// 世界原点的十字标记。没有它，空画布上平移缩放完全没有参照物。
    private func drawOriginMark(camera: CanvasCamera, palette: CanvasPalette) {
        let origin = camera.worldToView(CGPoint.zero)
        guard bounds.insetBy(dx: -40, dy: -40).contains(origin) else { return }
        let arm: CGFloat = 9
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.move(to: CGPoint(x: origin.x - arm, y: origin.y))
        path.line(to: CGPoint(x: origin.x + arm, y: origin.y))
        path.move(to: CGPoint(x: origin.x, y: origin.y - arm))
        path.line(to: CGPoint(x: origin.x, y: origin.y + arm))
        palette.originMark.setStroke()
        path.stroke()
    }

    /// 网格间距（世界单位）。
    ///
    /// 取 1/2/5 × 10ⁿ 序列里最接近 `targetSpacing` 视图点的那个值，这样缩放时
    /// 网格平滑换挡，不会出现一屏几百条线或一屏一条线。
    ///
    /// **取「最接近」而不是「向上取整」。** 第一版是向上取整（`< 2` 取 2、
    /// `< 5` 取 5、否则取 10），结果屏幕间距只能在 64–160pt 之间变化：缩放到
    /// 某些倍率时网格会稀疏到 160pt 一格，一屏只剩几根线，几乎失去参照作用。
    /// 判据写的是「最接近」，实现却是「不小于」，两者不一致——自检里的间距
    /// 区间断言把它兜住了。
    ///
    /// 阈值取相邻两项的几何中点（√2、√10、√50），这样换挡点在对数尺度上等距。
    static func gridStep(forZoom zoom: CGFloat, targetSpacing: CGFloat = 64) -> CGFloat {
        guard zoom > 0, zoom.isFinite else { return 0 }
        let raw = targetSpacing / zoom
        guard raw > 0, raw.isFinite else { return 0 }
        let magnitude = pow(10, (log10(raw)).rounded(.down))
        let normalized = raw / magnitude
        let multiplier: CGFloat
        if normalized < 2.squareRoot() {          // < 1.414 → 1
            multiplier = 1
        } else if normalized < 10.squareRoot() {  // < 3.162 → 2
            multiplier = 2
        } else if normalized < 50.squareRoot() {  // < 7.071 → 5
            multiplier = 5
        } else {                                  // → 10
            multiplier = 10
        }
        return multiplier * magnitude
    }
}

/// `CanvasCursor → NSCursor` 的翻译。
///
/// 放在这个文件里是刻意的：`CanvasInputEvent.swift` 与两个控制器都不 import
/// AppKit，所以"哪个指针长什么样"是宿主的决定。要改样式（比如把手柄上的
/// 十字换成缩放箭头）只改这一处。
extension CanvasCursor {
    var nsCursor: NSCursor {
        switch self {
        case .arrow: NSCursor.arrow
        case .crosshair: NSCursor.crosshair
        case .openHand: NSCursor.openHand
        case .closedHand: NSCursor.closedHand
        }
    }
}

/// 画布区域的配色。跟随系统外观，与 SwiftUI 侧的 `DesignTokens` 同源。
struct CanvasPalette {
    let background: NSColor
    let gridLine: NSColor
    let originMark: NSColor
    /// 选中外框与手柄描边。
    let selectionBorder: NSColor
    /// 手柄填充。
    let handleFill: NSColor
    /// 框选矩形的填充与描边。
    let marqueeFill: NSColor
    let marqueeBorder: NSColor

    static var current: CanvasPalette {
        CanvasPalette(
            background: NSColor(DesignTokens.Canvas.background),
            gridLine: NSColor(DesignTokens.Canvas.gridLine),
            originMark: NSColor(DesignTokens.Canvas.originMark),
            selectionBorder: NSColor(DesignTokens.Canvas.selectionBorder),
            handleFill: NSColor(DesignTokens.Canvas.handleFill),
            marqueeFill: NSColor(DesignTokens.Canvas.marqueeFill),
            marqueeBorder: NSColor(DesignTokens.Canvas.marqueeBorder)
        )
    }
}
