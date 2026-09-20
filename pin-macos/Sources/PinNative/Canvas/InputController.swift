import CoreGraphics
import Foundation
import QuartzCore

enum CanvasTool: Equatable {
    case select
    case hand
}

// 同样不 import AppKit：控制器只消费值对象，`CACurrentMediaTime` 来自 QuartzCore。
// 需要 AppKit 才能写出来的输入逻辑，说明它放错了层——翻译应该在
// `CanvasEventTranslation.swift` 里做完。

/// 输入路由与直接操控的总入口（路线图 §4 分工表里的 `InputController`）。
///
/// ## 它决定的唯一一件事：这一次输入归谁
///
/// ```text
///                    ┌─ 抓手 / 空格 / 中键 ─→ 平移（本类）
/// 指针 / 滚轮 / 键盘 ─┼─ 选择工具的指针 ──→ SelectionController（选择、拖动、缩放、框选）
///                    └─ 滚轮 / 捏合 ─────→ 缩放（本类）
/// ```
///
/// 路线图 §2.5 要求「输入统一在一处处理」：平移与缩放的两条路都在这里，
/// 选择那一条整体交给会话状态机。路由判断只做一次，不做"两边都试一下"——
/// 后者会让空格平移和框选同时发生。
///
/// ## 为什么不是 MinimalInputAdapter 的延伸
///
/// 那个类是批次 A 的临时件，只覆盖平移缩放，选择相关的入口全部留空。
/// 本类接管之后它被删除——路线图 §4 规则 3 明确**禁止维护两套同时生效的
/// 事件逻辑**，留着一个"也没坏"的旧实现，下次改手感时一定会有人改错那一份。
///
/// ## 严格按路线图 §2.5
///
/// - 滚动直接消费系统事件（含 `momentumPhase`），不叠加第二套衰减
/// - 鼠标拖拽平移松手即停，不加惯性
/// - 捏合与拖拽直接跟手，无追赶缓动
/// - 只有按钮缩放与「定位内容」使用缓动，且可被直接输入打断
@MainActor
final class InputController: CanvasInputAdapter {

    /// 空格键的虚拟键码。用它而不是字符：空格在中文输入法下 `characters`
    /// 是别的值，键码不随输入法也不随键盘布局变。
    static let spaceKeyCode: UInt16 = 49

    /// 正在平移画布。两种来源共用一套位移计算。
    private struct Panning {
        enum Source { case space, middle, hand }
        var origin: CGPoint
        var startCamera: CanvasCamera
        var source: Source
    }

    private var panning: Panning?

    /// 空格是否按住。按住期间左键拖拽也变成平移。
    private var isSpaceHeld = false
    private(set) var tool: CanvasTool = .select

    private var cameraAnimation: CameraAnimation?

    /// 选择与直接操控。本类只负责把指针交给他，不碰里面的状态。
    private let selection = SelectionController()

    /// 宿主。弱引用，理由见 `SelectionController.context`。
    private weak var context: CanvasContext?

    /// 由宿主在建立时注入一次。
    func attach(to context: CanvasContext) {
        self.context = context
        selection.attach(to: context)
    }

    func setTool(_ tool: CanvasTool, context: CanvasContext) {
        guard self.tool != tool else { return }
        self.tool = tool
        if panning == nil {
            context.setCursor(tool == .hand ? .openHand : .arrow)
        }
    }

    /// 自检探针：选择状态机。断言用它验证"这一次点击到底走了哪条路"。
    var selectionController: SelectionController { selection }

    // MARK: - 滚动与捏合

    func scrollWheel(_ input: CanvasScrollInput, context: CanvasContext) {
        // 路线图 §2.5：触控板滚动消费系统 momentumPhase。
        // 系统在手指离开后继续投递带 momentumPhase 的事件，衰减由系统完成——
        // 这里只做一次坐标换算，不再乘任何阻尼系数，否则会和系统手感叠加。
        //
        // 带 command 键的滚轮按惯例作为缩放，锚点为光标位置。
        let feel = context.motionConfiguration.feel

        if input.modifiers.contains(.command) {
            let factor = 1 + input.delta.height * feel.commandScrollZoomSensitivity
            cancelCameraAnimation()
            context.camera.zoom(by: factor, anchoredAtViewPoint: input.viewPoint)
            context.requestRedraw()
            return
        }

        guard input.delta != .zero else { return }
        cancelCameraAnimation()
        context.camera.translate(byViewDelta: panDelta(input.delta, input: input, feel: feel))
        context.requestRedraw()
    }

    /// 把滚动增量换算成视图点位移。
    ///
    /// **两种设备的增量不是一个量纲**：触控板给的是视图点，鼠标滚轮给的是行数
    /// （见 `CanvasScrollInput.delta` 的注释）。批次 A 起两类都按点数处理——
    /// 触控板是对的，鼠标滚轮则会慢得几乎不动。这个换算至今没做，因为
    /// **本机没有鼠标可实测**，凭猜给一个系数会把"手感已实机确认"这件事弄脏。
    /// 系数留在 `Feel.mouseWheelLinesToPoints`（当前 1，即保持现状）：
    /// 接上鼠标时改那一个字段，不必回来改算式。
    private func panDelta(
        _ delta: CGSize,
        input: CanvasScrollInput,
        feel: MotionConfiguration.Feel
    ) -> CGSize {
        let deviceScale = input.isPrecise ? 1 : feel.mouseWheelLinesToPoints
        let scale = feel.panSpeed * deviceScale
        return CGSize(width: delta.width * scale, height: delta.height * scale)
    }

    func magnify(_ input: CanvasMagnifyInput, context: CanvasContext) {
        // 直接跟手：用原始增量，不加缓动也不做插值。
        cancelCameraAnimation()
        let sensitivity = context.motionConfiguration.feel.magnifySensitivity
        context.camera.zoom(by: 1 + input.magnification * sensitivity,
                            anchoredAtViewPoint: input.viewPoint)
        context.requestRedraw()
    }

    // MARK: - 指针

    func pointerDown(_ input: CanvasPointerInput, context: CanvasContext) {
        cancelCameraAnimation()

        // 中键：任何时候都是平移，与空格无关（Figma、Blender、浏览器一致）。
        //
        // 每一条分支都要重设光标：进入平移之后指针该变成"握住的手"。
        // 漏掉这一句的表现是——按着空格拖动时指针还是张开的手，
        // 用户以为没抓住（自检里"拖动中指针是握住的手"抓的就是它）。
        if input.button == .other {
            beginPan(input, source: .middle, context: context)
            updateCursor(at: input.viewPoint, context: context)
            return
        }
        // 空格按住：左键也变成平移。这是"手不用离开鼠标就能挪画布"的那条路，
        // 也是空白拖动让给框选之后平移的主要出口。
        if isSpaceHeld {
            beginPan(input, source: .space, context: context)
            updateCursor(at: input.viewPoint, context: context)
            return
        }

        if tool == .hand, input.button == .left {
            beginPan(input, source: .hand, context: context)
            updateCursor(at: input.viewPoint, context: context)
            return
        }

        guard input.button == .left else { return }
        selection.pointerDown(input, context: context)
        updateCursor(at: input.viewPoint, context: context)
    }

    func pointerDragged(_ input: CanvasPointerInput, context: CanvasContext) {
        if panning != nil {
            applyPan(input, context: context)
            return
        }
        guard input.button == .left else { return }
        selection.pointerDragged(input, context: context)
    }

    func pointerUp(_ input: CanvasPointerInput, context: CanvasContext) {
        if panning != nil {
            // 路线图 §2.5：鼠标拖动画布不自动拥有系统滚动惯性，本期松手即停。
            panning = nil
            updateCursor(at: input.viewPoint, context: context)
            return
        }
        guard input.button == .left else { return }
        selection.pointerUp(input, context: context)
        updateCursor(at: input.viewPoint, context: context)
    }

    func pointerMoved(_ input: CanvasPointerInput, context: CanvasContext) {
        updateCursor(at: input.viewPoint, context: context)
    }

    func secondaryPointerDown(_ input: CanvasPointerInput, context: CanvasContext) {
        // 右键菜单属于后续批次（路线图 §3.2 之外）。这里刻意不实现，
        // 但**要让宿主知道没消费**——见 CanvasHostNSView 里的 rightMouseDown。
    }

    // MARK: - 平移

    private func beginPan(
        _ input: CanvasPointerInput,
        source: Panning.Source,
        context: CanvasContext
    ) {
        panning = Panning(origin: input.viewPoint, startCamera: context.camera, source: source)
    }

    /// 自检探针：现在是不是在拖动画布。
    var isPanning: Bool { panning != nil }

    /// 自检探针：待平移状态（空格按住）。
    var isSpacePanReady: Bool { isSpaceHeld }

    private func applyPan(_ input: CanvasPointerInput, context: CanvasContext) {
        guard let panning else { return }
        // 从按下时的相机状态重新计算，避免逐帧累加带来的漂移。
        var camera = panning.startCamera
        camera.translate(byViewDelta: CGSize(
            width: input.viewPoint.x - panning.origin.x,
            height: input.viewPoint.y - panning.origin.y
        ))
        context.camera = camera
        context.requestRedraw()
    }

    // MARK: - 键盘

    func keyDown(_ input: CanvasKeyInput, context: CanvasContext) -> Bool {
        // 空格：按住期间把左键拖拽变成平移（Figma / Sketch / 预览的通行做法）。
        // 自动重复要吃掉但不再处理——按住空格不放会连发，每次重设一遍光标
        // 会让光标闪。
        if input.keyCode == Self.spaceKeyCode {
            guard !input.isARepeat else { return true }
            isSpaceHeld = true
            context.setCursor(.openHand)
            return true
        }
        // Escape 在待平移状态下取消它：进入了一个模式却退不出来，
        // 用户的第一反应就是按 Escape。
        if input.keyCode == 53, isSpaceHeld {
            isSpaceHeld = false
            context.setCursor(.arrow)
            return false    // 不消费：Escape 同时还要能清空选择
        }
        return selection.keyDown(input, context: context)
    }

    func keyUp(_ input: CanvasKeyInput, context: CanvasContext) {
        // 空格松开 = 退出待平移。**没有这一条，空格按一下之后就永远在平移**，
        // 而且看不出原因——所以宿主必须转发 keyUp（见 CanvasHostNSView）。
        guard input.keyCode == Self.spaceKeyCode else { return }
        isSpaceHeld = false
        // 平移进行到一半时松开空格：这次拖拽走完，不中途变卦。
        if panning == nil { context.setCursor(tool == .hand ? .openHand : .arrow) }
    }

    func flagsChanged(_ modifiers: CanvasModifiers, context: CanvasContext) {
        // 目前没有"按住某修饰键切换模式"的输入：Shift 的加选 / 等比 / 锁轴
        // 都在各自事件的 `modifiers` 里读，Option 复制拖动属于后续批次。
        // 留这个空实现是为了让上面的结论有地方写——协议里有这条通道，
        // 而"通道在但没人用"必须一眼看得出来。
    }

    func selectionDidChange(context: CanvasContext) {
        selection.pushOverlay(context: context)
    }

    // MARK: - 光标

    /// 平移状态 > 空格状态 > 抓手工具 > 选择状态。
    ///
    /// 顺序就是优先级：正在拖动画布时哪怕空格松了，指针也该是"握住的手"。
    private func updateCursor(at viewPoint: CGPoint, context: CanvasContext) {
        if panning != nil {
            context.setCursor(.closedHand)
            return
        }
        if isSpaceHeld {
            context.setCursor(.openHand)
            return
        }
        if tool == .hand {
            context.setCursor(.openHand)
            return
        }
        context.setCursor(selection.cursor(at: viewPoint, context: context))
    }

    // MARK: - 程序化定位（本批次唯一使用缓动的路径）

    func zoomTo(_ zoom: CGFloat, context: CanvasContext) {
        var target = context.camera
        target.setZoom(zoom)
        animate(to: target, context: context)
    }

    func zoomStep(_ factor: CGFloat, context: CanvasContext) {
        var target = context.camera
        target.setZoom(context.camera.zoom * factor)
        animate(to: target, context: context)
    }

    func focus(on worldRect: CGRect, context: CanvasContext) {
        var target = context.camera
        target.fit(worldRect: worldRect)
        animate(to: target, context: context)
    }

    /// 自检探针：有没有缓动在播。断言用它验证"直接操控能打断程序动画"。
    var isAnimatingCamera: Bool { cameraAnimation != nil }

    private func animate(to target: CanvasCamera, context: CanvasContext) {
        let configuration = context.motionConfiguration
        // 路线图 §3.2：支持「降低动态效果」。开启时直接跳到终态。
        guard !configuration.reduceMotion, configuration.programmaticCameraDuration > 0 else {
            cancelCameraAnimation()
            context.camera = target
            context.requestRedraw()
            return
        }
        cancelCameraAnimation()
        let animation = CameraAnimation(
            from: context.camera,
            to: target,
            duration: configuration.programmaticCameraDuration,
            curve: configuration.programmaticCameraCurve,
            frameInterval: configuration.feel.animationFrameInterval
        )
        cameraAnimation = animation
        animation.start { [weak self] camera in
            context.camera = camera
            context.requestRedraw()
            if camera == target { self?.cameraAnimation = nil }
        }
    }

    private func cancelCameraAnimation() {
        // 路线图 §3.2：动画可被新的直接输入打断。
        cameraAnimation?.cancel()
        cameraAnimation = nil
    }
}

/// 临时的相机缓动驱动。
///
/// **临时实现**：批次 C 之后由 Codex 的 `Canvas/ZoomAnimator.swift` 取代
/// （路线图 §4 分工表把动画层划给了交互精修批次）。之所以现在就写，是因为
/// 路线图 §2.5 要求按钮缩放带缓动、§3.2 要求可被打断，而一个跳变的实现
/// 无法验证这两个要求。
///
/// 这里用主 actor 上的 `Task` 循环而不是 `Timer` 或 `CVDisplayLink`，是刻意的简化：
/// 本批次没有逐帧内容要推进，只有相机一条曲线，而 `Task.sleep` 天然继承 actor
/// 隔离、天然可取消，不需要 `@Sendable` 包装里再往回跳一次 actor。
/// 真正的帧调度（路线图 §2.3「按显示节奏推进，空闲时停止」）属于动画层。
@MainActor
final class CameraAnimation {
    private let from: CanvasCamera
    private let to: CanvasCamera
    private let duration: TimeInterval
    private let curve: MotionCurve
    /// 每帧间隔。由 `MotionConfiguration.feel.animationFrameInterval` 注入
    /// （默认 8ms ≈ 120Hz，与实际刷新节奏对齐）：它是手感参数，不是常量。
    private let frameInterval: Duration
    private var task: Task<Void, Never>?
    private var startTime: TimeInterval = 0

    init(
        from: CanvasCamera,
        to: CanvasCamera,
        duration: TimeInterval,
        curve: MotionCurve,
        frameInterval: TimeInterval
    ) {
        self.from = from
        self.to = to
        self.duration = duration
        self.curve = curve
        // 兜底到 1ms：0 或负数会让 `Task.sleep` 变成忙等，
        // 表现是动画期间 CPU 满载、风扇起飞——参数可调之后这种输入迟早会出现。
        self.frameInterval = .seconds(max(0.001, frameInterval))
    }

    func start(onUpdate: @escaping @MainActor (CanvasCamera) -> Void) {
        cancel()
        startTime = CACurrentMediaTime()
        // 帧间隔在进循环之前取出来：`frameInterval` 是实例属性（不是
        // `static let`），循环里每帧读一次属性没有必要，而且那会让"帧间隔在
        // 动画播放到一半时被改掉"变成可能——那不是我们想要的语义。
        let frameInterval = self.frameInterval
        task = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                let elapsed = CACurrentMediaTime() - self.startTime
                let t = min(elapsed / self.duration, 1)
                onUpdate(self.interpolate(at: self.curve.progress(at: t)))
                if t >= 1 {
                    self.task = nil
                    return
                }
                try? await Task.sleep(for: frameInterval)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// 相机插值按 log(zoom) 线性推进，而不是对 zoom 本身线性插值——
    /// 后者在跨倍率缩放时速度感明显不均（100%→200% 和 100%→400% 后半段一样快）。
    private func interpolate(at progress: Double) -> CanvasCamera {
        var result = to
        result.zoom = CGFloat(
            exp(log(Double(from.zoom)) + (log(Double(to.zoom)) - log(Double(from.zoom))) * progress)
        )
        result.center = CGPoint(
            x: from.center.x + (to.center.x - from.center.x) * progress,
            y: from.center.y + (to.center.y - from.center.y) * progress
        )
        return result
    }
}
