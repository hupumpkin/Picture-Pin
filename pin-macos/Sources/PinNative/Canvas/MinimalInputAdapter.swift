import Foundation
import QuartzCore

// 同样不 import AppKit：适配器只消费值对象，`CACurrentMediaTime` 来自 QuartzCore。
// 需要 AppKit 才能写出来的输入逻辑，说明它放错了层——翻译应该在
// `CanvasEventTranslation.swift` 里做完。

/// CC 的临时最小输入适配器（路线图 §4 规则 3）。
///
/// **这是临时实现，批次 B 之后由 Codex 的 `Canvas/InputController.swift` 替换。**
/// 它只覆盖本批次真正需要的输入：平移、捏合缩放、按钮缩放、定位内容。
/// 选择、框选、多选、拖拽元素、快捷键一律不在这里实现——那些是 Codex 的
/// `InputController.swift` 与 `SelectionController.swift` 的范围，本文件里
/// 对应的入口留空并注明，是为了让"缺什么"一眼可见，而不是散落在注释里。
///
/// 严格按路线图 §2.5 实现：
/// - 滚动直接消费系统事件（含 `momentumPhase`），不叠加第二套衰减
/// - 鼠标拖拽平移松手即停，不加惯性
/// - 捏合与拖拽直接跟手，无追赶缓动
/// - 只有按钮缩放与「定位内容」使用缓动
@MainActor
final class MinimalInputAdapter: CanvasInputAdapter {

    /// 相机拖拽平移的起点（视图坐标）。
    private var dragOrigin: CGPoint?
    private var dragStartCamera: CanvasCamera?
    private var cameraAnimation: CameraAnimation?

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
        // 批次 B（Codex）：先 `context.hitTest(worldPoint:)`，命中则进入选择 / 拖动元素，
        // 未命中才落到下面的画布平移。元素拖动用 `context.perform(.setFrame(...))`，
        // 并在抬起时登记一次撤销（不要每次增量都登记）。
        cancelCameraAnimation()
        dragOrigin = input.viewPoint
        dragStartCamera = context.camera
    }

    func pointerDragged(_ input: CanvasPointerInput, context: CanvasContext) {
        guard let origin = dragOrigin, let startCamera = dragStartCamera else { return }
        // 从按下时的相机状态重新计算，避免逐帧累加带来的漂移。
        var camera = startCamera
        camera.translate(byViewDelta: CGSize(
            width: input.viewPoint.x - origin.x,
            height: input.viewPoint.y - origin.y
        ))
        context.camera = camera
        context.requestRedraw()
    }

    func pointerUp(_ input: CanvasPointerInput, context: CanvasContext) {
        // 路线图 §2.5：鼠标拖动画布不自动拥有系统滚动惯性，本期松手即停。
        dragOrigin = nil
        dragStartCamera = nil
        cancelCameraAnimation()
    }

    func pointerMoved(_ input: CanvasPointerInput, context: CanvasContext) {
        // 批次 B（Codex）：悬停高亮与手柄光标反馈走这里。
    }

    func secondaryPointerDown(_ input: CanvasPointerInput, context: CanvasContext) {
        // 批次 B（Codex）：空白处弹出画布菜单，元素上弹出元素菜单。
    }

    // MARK: - 键盘

    func keyDown(_ input: CanvasKeyInput, context: CanvasContext) -> Bool {
        // 批次 B（Codex）：方向键微移、Delete 删除、Command+A 全选、Escape 取消选择。
        // 在此之前一律返回 false，让宿主按常规向上传递（未消费的按键会响一声，
        // 这是 macOS 的默认反馈，比默默吞掉更容易发现"快捷键没接上"）。
        false
    }

    func flagsChanged(_ modifiers: CanvasModifiers, context: CanvasContext) {
        // 批次 B（Codex）：按住 Shift 切到加选、按住 Option 切到复制拖动。
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
/// **临时实现**：批次 B 由 Codex 的 `Canvas/ZoomAnimator.swift` 取代。
/// 之所以现在就写，是因为路线图 §2.5 要求按钮缩放带缓动、§3.2 要求可被打断，
/// 而一个跳变的实现无法验证这两个要求。
///
/// 这里用主 actor 上的 `Task` 循环而不是 `Timer` 或 `CVDisplayLink`，是刻意的简化：
/// 本批次没有逐帧内容要推进，只有相机一条曲线，而 `Task.sleep` 天然继承 actor
/// 隔离、天然可取消，不需要 `@Sendable` 包装里再往回跳一次 actor。
/// 真正的帧调度（路线图 §2.3「按显示节奏推进，空闲时停止」）属于 Codex 的动画层。
@MainActor
private final class CameraAnimation {
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
        // 兜底到 8ms：0 或负数会让 `Task.sleep` 变成忙等，
        // 表现是动画期间 CPU 满载、风扇起飞——参数可调之后这种输入迟早会出现。
        self.frameInterval = .seconds(max(0.001, frameInterval))
    }

    func start(onUpdate: @escaping @MainActor (CanvasCamera) -> Void) {
        cancel()
        startTime = CACurrentMediaTime()
        // 帧间隔在进循环之前取出来：`frameInterval` 现在是实例属性（不再是
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
