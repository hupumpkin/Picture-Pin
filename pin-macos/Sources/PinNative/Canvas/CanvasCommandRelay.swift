import CoreGraphics

/// 工具栏 → 画布的命令通道。
///
/// 为什么不让工具栏直接调相机：缩放按钮必须**经过输入适配器**，才能走和触控板
/// 捏合、快捷键同一条路径（同样的锚点规则、同样的缓动、同样的可打断性）。
/// 工具栏若自己改 `camera.zoom`，就会出现「按钮缩放没有动画」这类不一致，
/// 而且批次 B 换掉输入实现时它会变成漏网之鱼。
///
/// 所以工具栏只说「放大一档」，具体怎么做由适配器决定。闭包由 `CanvasHostView`
/// 在建立协调器时填入；尚未挂载时全部为 `nil`，工具栏按钮相应地不可用。
@MainActor
final class CanvasCommandRelay {
    var zoomStep: ((CGFloat) -> Void)?
    var zoomTo: ((CGFloat) -> Void)?
    var focusContent: (() -> Void)?
    var focusSelection: (() -> Void)?

    /// 是否已经挂载。工具栏用它禁用按钮，避免点了没反应。
    var isAttached: Bool { zoomStep != nil }
}
