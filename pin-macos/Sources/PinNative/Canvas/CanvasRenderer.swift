import CoreGraphics

/// 渲染增量：渲染器一次事务消费的内容（路线图 §4 规则 2 的接口冻结项之一）。
///
/// 用批量结构而不是逐条调用，是为了让渲染器能把一次相机变化 + 若干元素变化
/// 合成一次图层提交，而不是每来一条就提交一次。
struct CanvasRenderUpdate: Equatable, Sendable {
    var inserted: [CanvasElement] = []
    var updated: [CanvasElement] = []
    var removed: [CanvasElementID] = []
    /// 完整绘制顺序。为 `nil` 表示顺序未变。
    var order: [CanvasElementID]?
    /// 相机状态。为 `nil` 表示相机未变，渲染器可以跳过变换更新。
    var camera: CanvasCamera?
    /// 覆盖层描述。为 `nil` 表示覆盖层未变。
    var overlay: CanvasOverlay?

    var isEmpty: Bool {
        inserted.isEmpty && updated.isEmpty && removed.isEmpty
            && order == nil && camera == nil && overlay == nil
    }

    init(
        inserted: [CanvasElement] = [],
        updated: [CanvasElement] = [],
        removed: [CanvasElementID] = [],
        order: [CanvasElementID]? = nil,
        camera: CanvasCamera? = nil,
        overlay: CanvasOverlay? = nil
    ) {
        self.inserted = inserted
        self.updated = updated
        self.removed = removed
        self.order = order
        self.camera = camera
        self.overlay = overlay
    }

    /// 从一次场景变更构造渲染增量。
    ///
    /// `CanvasSceneChange` 自带顺序信息，所以这个构造器是全量的——
    /// 调用方不必再补任何字段，也就不会漏掉某一项。
    init(change: CanvasSceneChange, camera: CanvasCamera? = nil, overlay: CanvasOverlay? = nil) {
        self.init(
            inserted: change.inserted,
            updated: change.updated,
            removed: change.removed,
            order: change.order,
            camera: camera,
            overlay: overlay
        )
    }
}

/// 屏幕空间覆盖层的描述。
///
/// 覆盖层元素（选择框、变换手柄、对齐辅助线）的**位置**由世界坐标给定，
/// **尺寸**一律按视图点计算，不随画布缩放变粗变细（路线图 §2.3、§3.2）。
/// 把尺寸换算交给渲染器，是为了让"手柄看起来多大"只有一处定义。
///
/// 本批次只定义结构，选择与吸附由 Codex 在批次 C/D 填充
/// （路线图 §3.2：吸附放到交互精修批次）。
struct CanvasOverlay: Equatable, Sendable {
    /// 选中元素的外框，世界坐标。
    var selectionFrames: [CGRect] = []
    /// 对齐辅助线，世界坐标。
    var guides: [Guide] = []

    struct Guide: Equatable, Sendable {
        enum Axis: Equatable, Sendable { case vertical, horizontal }
        var axis: Axis
        /// 垂直辅助线的 x，或水平辅助线的 y，世界坐标。
        var position: CGFloat
        /// 辅助线在另一轴上的延伸范围，世界坐标。
        var extent: ClosedRange<CGFloat>
    }

    static let empty = CanvasOverlay()
    var isEmpty: Bool { selectionFrames.isEmpty && guides.isEmpty }
}

/// 渲染器协议。
///
/// **契约：实现方不得依赖场景图与相机的内部结构**——场景、相机数学、命中测试
/// 都不依赖 CALayer（路线图 §2.2）。协议只覆盖当期真实需求，不提前搭插件系统，
/// 也不实现 MetalRenderer。
///
/// 主线程约定：`apply` 与 `setMotionConfiguration` 均在主线程调用。
@MainActor
protocol CanvasRenderer: AnyObject {
    /// 渲染器当前使用的相机。视图尺寸变化时由宿主更新。
    var camera: CanvasCamera { get set }

    /// 应用一次渲染增量。空增量应当被安全忽略。
    func apply(_ update: CanvasRenderUpdate)

    /// 注入动画参数。渲染器只读，不修改。
    func setMotionConfiguration(_ configuration: MotionConfiguration)

    /// 视图 backing scale 变化（换显示器、进入高密度屏）时调用。
    func setBackingScaleFactor(_ scale: CGFloat)
}
