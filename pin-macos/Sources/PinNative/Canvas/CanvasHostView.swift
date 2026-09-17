import AppKit
import SwiftUI

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
    let configuration: MotionConfiguration
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
            onCameraChange: onCameraChange
        )
    }

    func makeNSView(context: Context) -> CanvasHostNSView {
        let view = CanvasHostNSView()
        view.context = context.coordinator
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: CanvasHostNSView, context: Context) {
        context.coordinator.onCameraChange = onCameraChange
        context.coordinator.setMotionConfiguration(configuration)
        context.coordinator.applyExternalCamera(camera)
        context.coordinator.applyExternalScene(scene)
        // 场景之后：换画布时先让渲染器重建内容，再落新的选择。
        context.coordinator.applyExternalSelection(selection)
    }

    @MainActor
    final class Coordinator: CanvasContext {
        private weak var view: CanvasHostNSView?
        private let renderer: LayerRenderer
        /// 路线图 §4 规则 3：临时最小输入适配器，批次 B 由 Codex 的
        /// `InputController.swift` 替换。替换点就是这一行。
        private let input: CanvasInputAdapter = MinimalInputAdapter()

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
            commands: CanvasCommandRelay,
            onSceneChange: @escaping (CanvasScene) -> Void,
            onSelectionChange: @escaping (Set<CanvasElementID>) -> Void,
            onCameraChange: @escaping (CanvasCamera) -> Void
        ) {
            self.scene = scene
            self.selection = selection
            self.renderer = LayerRenderer(camera: camera, configuration: configuration, images: images)
            // 起点是"同一块画布的空场景"：这样首次 `syncScene()` 会把已有元素
            // 全部判为 inserted，非空初始场景也能一次画出来。
            self.syncedScene = CanvasScene(boardID: scene.boardID)
            self.commands = commands
            self.motionConfiguration = configuration
            self.onSceneChange = onSceneChange
            self.onSelectionChange = onSelectionChange
            self.onCameraChange = onCameraChange
            self.reportedCamera = camera
            renderer.setMotionConfiguration(configuration)
        }

        func attach(to view: CanvasHostNSView) {
            self.view = view
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
        }

        func requestRedraw() {
            view?.needsDisplay = true
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
            if boardChanged { discardOverlay() }
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
            if button == .left {
                input.pointerDown(pointer, context: self)
            } else {
                input.secondaryPointerDown(pointer, context: self)
            }
            view.needsDisplay = true
        }

        func pointerDragged(_ event: NSEvent, button: CanvasPointerButton) {
            guard let view else { return }
            guard button == .left else { return }
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
            guard button == .left else { return }
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

        /// 某个元素图层里实际的像素尺寸。读的是 `layer.contents`，
        /// 不是渲染器的记账——否则断言是自证。
        func renderedImageSize(of id: CanvasElementID) -> CGSize? {
            renderer.sublayerImageSize(of: id)
        }

        /// 某个元素当前显示的档位。
        func renderedTier(of id: CanvasElementID) -> LODTier? { renderer.sublayerTier(of: id) }

        /// 取不到像素的元素及原因。
        var renderedImageFailures: [CanvasElementID: String] { renderer.imageFailures }

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
    }
}

/// AppKit 画布表面。
///
/// 只做三件事：转发输入、绘制背景网格、把尺寸变化告诉协调器。
/// 所有画布状态都在协调器与渲染器里，视图本身不持有相机。
final class CanvasHostNSView: NSView {
    weak var context: CanvasHostView.Coordinator?

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

    override func rightMouseDown(with event: NSEvent) {
        context?.pointerDown(event, button: .right)
    }

    override func rightMouseDragged(with event: NSEvent) {
        context?.pointerDragged(event, button: .right)
    }

    override func rightMouseUp(with event: NSEvent) {
        context?.pointerUp(event, button: .right)
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

    override func flagsChanged(with event: NSEvent) {
        context?.flagsChanged(event)
    }

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

/// 画布区域的配色。跟随系统外观，与 SwiftUI 侧的 `DesignTokens` 同源。
struct CanvasPalette {
    let background: NSColor
    let gridLine: NSColor
    let originMark: NSColor

    static var current: CanvasPalette {
        CanvasPalette(
            background: NSColor(DesignTokens.Canvas.background),
            gridLine: NSColor(DesignTokens.Canvas.gridLine),
            originMark: NSColor(DesignTokens.Canvas.originMark)
        )
    }
}
