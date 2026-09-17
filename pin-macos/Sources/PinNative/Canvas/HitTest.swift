import CoreGraphics

/// 命中与空间查询（路线图 §4 规则 2 的接口冻结项之一）。
///
/// 这组查询同时服务三方：选择（点中哪个元素、框选到哪些）、吸附
/// （附近有哪些候选）、以及后续的辅助线。三者**必须共用同一套坐标与阈值**
/// ——路线图 §3.2 明确要求「辅助线显示和实际吸附使用相同坐标与阈值」，
/// 各自实现一份比较逻辑是这条要求最常见的失效方式。
///
/// 本批次是朴素实现：元素数量在 O(10²) 量级时线性扫描足够。批次 B 测出真实
/// 元素规模后，若扫描成为热点再引入空间索引，届时只换实现、不换接口。
enum CanvasHitTest {

    /// 命中世界坐标下最靠上的元素。
    ///
    /// 从绘制顺序的顶部往下找，第一个命中的即为结果。空白处返回 `nil`。
    static func topmostElement(
        at worldPoint: CGPoint,
        in scene: CanvasScene
    ) -> CanvasElementID? {
        // elements 已按 order 升序，所以反向遍历就是从最上层开始。
        scene.elements.reversed().first { $0.frame.contains(worldPoint) }?.id
    }

    /// 矩形范围内的元素（框选）。
    ///
    /// 采用相交而非包含：框选经过元素边缘时也应选中它，这是设计工具的通行行为。
    static func elements(
        intersecting worldRect: CGRect,
        in scene: CanvasScene
    ) -> [CanvasElementID] {
        scene.elements
            .filter { $0.frame.intersects(worldRect) }
            .map(\.id)
    }

    /// 某个元素外框附近的候选元素，供吸附使用。
    ///
    /// `tolerance` 的单位是**世界单位**，由调用方从屏幕点换算后再传入
    /// （`tolerance / camera.zoom`）——路线图 §3.2 要求吸附距离用屏幕点定义，
    /// 这样缩放时吸附手感才一致。换算放在调用方，是为了让本查询保持纯几何、
    /// 不依赖相机。
    static func neighbors(
        of id: CanvasElementID,
        within tolerance: CGFloat,
        in scene: CanvasScene
    ) -> [CanvasElement] {
        guard let subject = scene.element(id) else { return [] }
        let searchRect = subject.frame.insetBy(dx: -tolerance, dy: -tolerance)
        return scene.elements.filter { $0.id != id && $0.frame.intersects(searchRect) }
    }
}
