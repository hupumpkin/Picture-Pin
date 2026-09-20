import CoreGraphics

/// 画布相机：定义世界坐标与视图坐标之间的映射。
///
/// **三个坐标空间**（路线图 §4 规则 2 要求冻结的接口之一）：
///
/// | 空间 | 单位 | 原点 | 谁在用 |
/// | --- | --- | --- | --- |
/// | `world` | 世界单位 | 画布原点，与缩放无关 | 元素 model、命中、吸附、辅助线 |
/// | `view` | 视图点 | 画布宿主左上角，y 向下 | 输入事件、覆盖层、手柄尺寸 |
/// | `screen` | 设备像素 | 同 view | 图片 LOD 解码尺寸（view × backingScaleFactor） |
///
/// 元素的位置一律存 `world`，任何"多少个屏幕点"的尺寸一律存 `view`。
/// 两者混用是画布类 bug 的主要来源，所以这里只提供显式换算，不提供隐式运算。
///
/// 本类型是纯数学，**不含任何动画**（路线图 §2.2）。缓动与打断属于 Codex 的
/// `Canvas/Motion.swift` 与 `ZoomAnimator.swift`。
struct CanvasCamera: Equatable, Sendable, Codable {
    /// 视口中心对应的世界坐标点。
    var center: CGPoint
    /// 每个世界单位对应多少个视图点。`1.0` 即 100%。
    var zoom: CGFloat
    /// 视口尺寸，单位为视图点。
    var viewportSize: CGSize

    static let minZoom: CGFloat = 0.02
    static let maxZoom: CGFloat = 64

    static let identity = CanvasCamera(
        center: .zero,
        zoom: 1,
        viewportSize: CGSize(width: 1, height: 1)
    )

    /// 启动时的相机。
    ///
    /// `viewportSize` 这里是**占位值**：真实尺寸要等宿主视图首次布局才知道，
    /// 届时由宿主写入（`CanvasHostView.Coordinator.updateViewport`）。用占位值
    /// 而不是 1×1，是为了在首帧到达之前，任何按视口尺寸做的计算（比如
    /// `visibleWorldRect`）不会退化成除零或空集。
    static let initial = CanvasCamera(
        center: .zero,
        zoom: 1,
        viewportSize: CGSize(width: 800, height: 600)
    )

    // MARK: - 换算

    func worldToView(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - center.x) * zoom + viewportSize.width / 2,
            y: (point.y - center.y) * zoom + viewportSize.height / 2
        )
    }

    func viewToWorld(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - viewportSize.width / 2) / zoom + center.x,
            y: (point.y - viewportSize.height / 2) / zoom + center.y
        )
    }

    func worldToView(_ rect: CGRect) -> CGRect {
        let origin = worldToView(rect.origin)
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: rect.width * zoom,
            height: rect.height * zoom
        )
    }

    func viewToWorld(_ rect: CGRect) -> CGRect {
        let origin = viewToWorld(rect.origin)
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: rect.width / zoom,
            height: rect.height / zoom
        )
    }

    /// 当前可见的世界矩形。
    ///
    /// `preloadMargin` 是视口外的预加载边距（单位：视图点），供视口虚拟化使用
    /// （路线图 §2.3）。边距值属于参数，由 Codex 的 `MotionConfiguration` 提供。
    func visibleWorldRect(preloadMargin: CGFloat = 0) -> CGRect {
        let expanded = CGRect(origin: .zero, size: viewportSize)
            .insetBy(dx: -preloadMargin, dy: -preloadMargin)
        return viewToWorld(expanded)
    }

    // MARK: - 直接操控
    //
    // 下面是相机的最小变更操作。它们**立即生效**，不加缓动——
    // 路线图 §2.5 要求捏合与拖拽直接跟手，§3.2 要求直接操控无额外追赶缓动。

    /// 按视图点位移平移相机。
    mutating func translate(byViewDelta delta: CGSize) {
        center.x -= delta.width / zoom
        center.y -= delta.height / zoom
    }

    /// 以某个视图点为锚点缩放，保证该点下的世界坐标保持不动。
    ///
    /// 这是路线图 §3.2「缩放锚点稳定」的核心：连续捏合后光标下的内容不应漂移。
    mutating func zoom(by factor: CGFloat, anchoredAtViewPoint anchor: CGPoint) {
        let worldUnderAnchor = viewToWorld(anchor)
        let newZoom = (zoom * factor).clamped(to: Self.minZoom...Self.maxZoom)
        guard newZoom != zoom else { return }
        zoom = newZoom
        // 反解出让 worldUnderAnchor 仍落在 anchor 上所需的 center
        center = CGPoint(
            x: worldUnderAnchor.x - (anchor.x - viewportSize.width / 2) / zoom,
            y: worldUnderAnchor.y - (anchor.y - viewportSize.height / 2) / zoom
        )
    }

    /// 缩放到指定倍率，锚点为视口中心。用于按钮缩放与「定位内容」。
    mutating func setZoom(_ newZoom: CGFloat) {
        zoom = newZoom.clamped(to: Self.minZoom...Self.maxZoom)
    }

    /// 把世界矩形装进视口并留出内边距。视口为空或矩形为空时回到原点。
    mutating func fit(worldRect rect: CGRect, padding: CGFloat = 48) {
        guard rect.width > 0, rect.height > 0,
              viewportSize.width > padding * 2, viewportSize.height > padding * 2
        else {
            center = rect.isEmpty ? .zero : CGPoint(x: rect.midX, y: rect.midY)
            zoom = 1
            return
        }
        center = CGPoint(x: rect.midX, y: rect.midY)
        let scaleX = (viewportSize.width - padding * 2) / rect.width
        let scaleY = (viewportSize.height - padding * 2) / rect.height
        zoom = min(scaleX, scaleY).clamped(to: Self.minZoom...Self.maxZoom)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
