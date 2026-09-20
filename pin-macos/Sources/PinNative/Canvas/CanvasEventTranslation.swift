import AppKit

// `NSEvent → 输入值对象` 的翻译层。
//
// 这是整个输入路径上**唯一**依赖 AppKit 的一步，刻意单独成文件：控制器只消费
// `CanvasInputEvent.swift` 里的值对象，所以它可以在测试里被直接喂输入，
// 不需要真实窗口、真实键盘或真实触控板。
//
// 翻译一律走 `NSView.convert(_:from: nil)` 得到视图坐标（原点左上、y 向下），
// 与 `CanvasCamera` 的约定一致——宿主视图是 flipped 的，这一步由 AppKit 保证。
// 世界坐标顺手一起给：消费方几乎总是需要它，而且只有这里同时握着视图和相机。

extension CanvasModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var result: CanvasModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        self = result
    }
}

extension CanvasScrollPhase {
    init(_ phase: NSEvent.Phase) {
        var result: CanvasScrollPhase = []
        if phase.contains(.began) { result.insert(.began) }
        if phase.contains(.changed) { result.insert(.changed) }
        if phase.contains(.ended) { result.insert(.ended) }
        if phase.contains(.cancelled) { result.insert(.cancelled) }
        if phase.contains(.mayBegin) { result.insert(.mayBegin) }
        if phase.contains(.stationary) { result.insert(.stationary) }
        self = result
    }
}

@MainActor
enum CanvasEventTranslation {

    /// 事件位置 → 视图坐标。宿主视图是 flipped，convert 之后即为原点左上、y 向下。
    static func viewPoint(of event: NSEvent, in view: NSView) -> CGPoint {
        view.convert(event.locationInWindow, from: nil)
    }

    static func pointer(
        _ event: NSEvent,
        in view: NSView,
        camera: CanvasCamera,
        button: CanvasPointerButton
    ) -> CanvasPointerInput {
        let viewPoint = viewPoint(of: event, in: view)
        return CanvasPointerInput(
            viewPoint: viewPoint,
            worldPoint: camera.viewToWorld(viewPoint),
            modifiers: CanvasModifiers(event.modifierFlags),
            clickCount: max(event.clickCount, 1),
            button: button,
            timestamp: event.timestamp
        )
    }

    /// `delta` 原样透传 `scrollingDeltaX/Y`，**不做单位归一化**。
    ///
    /// AppKit 对触控板给的是点、对鼠标滚轮给的是行，两者粒度差一个量级。
    /// 归一化会直接改变滚动手感，而当前手感是用户实机确认过的，所以这一步
    /// 留给批次 B 连同真实设备一起调，届时用 `isPrecise` 区分即可。
    static func scroll(_ event: NSEvent, in view: NSView, camera: CanvasCamera) -> CanvasScrollInput {
        let viewPoint = viewPoint(of: event, in: view)
        return CanvasScrollInput(
            viewPoint: viewPoint,
            worldPoint: camera.viewToWorld(viewPoint),
            delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
            isPrecise: event.hasPreciseScrollingDeltas,
            phase: CanvasScrollPhase(event.phase),
            momentumPhase: CanvasScrollPhase(event.momentumPhase),
            modifiers: CanvasModifiers(event.modifierFlags)
        )
    }

    static func magnify(_ event: NSEvent, in view: NSView, camera: CanvasCamera) -> CanvasMagnifyInput {
        let viewPoint = viewPoint(of: event, in: view)
        return CanvasMagnifyInput(
            viewPoint: viewPoint,
            worldPoint: camera.viewToWorld(viewPoint),
            magnification: event.magnification,
            phase: CanvasScrollPhase(event.phase),
            modifiers: CanvasModifiers(event.modifierFlags)
        )
    }

    static func key(_ event: NSEvent) -> CanvasKeyInput {
        CanvasKeyInput(
            characters: event.characters ?? "",
            keyCode: event.keyCode,
            modifiers: CanvasModifiers(event.modifierFlags),
            isARepeat: event.isARepeat
        )
    }
}
