import CoreGraphics

/// 选择与缩放的纯几何：手柄在哪、点中哪个、拖到哪变成多大。
///
/// ## 为什么单独成文件
///
/// 这三件事必须能脱离窗口直接断言。手柄位置算错的表现是"手柄看得见但点不中"，
/// 靠肉眼要点很多次才看得出来；而缩放的算式（锚点、等比、最小边长）一旦写错，
/// 表现是"图片会翻面"或"拖到某个方向就缩没了"——都是纯几何能一网打尽的错。
/// 与 `HitTest.swift` 同一条规矩：纯函数、不 import AppKit、不依赖控制器状态。
///
/// ## 坐标口径（路线图 §2.3、§3.2）
///
/// - **位置**：世界坐标。手柄中心由外框 + 相机投影得出，本身不存。
/// - **尺寸**：一律视图点。手柄边长、命中区外扩都不随缩放变化——
///   路线图要求"选择手柄保持固定屏幕大小"，而"手柄看起来多大"只有这里一处定义，
///   渲染器画的时候读的是同一组常量。
enum SelectionGeometry {

    /// 手柄边长（视图点）。
    static let handleSize: CGFloat = 9

    /// 手柄命中区在边长之外再外扩的量（视图点）。
    /// 画 9pt、抓 19pt：手柄要"看得清但不碍事"，而点击精度是按手给的。
    static let handleHitSlop: CGFloat = 5

    /// 选中外框的描边宽度（视图点）。同样不随缩放变化。
    static let borderWidth: CGFloat = 1.5

    /// 框选矩形的虚线节奏（视图点）。与选中框区分开——两者同时出现时
    /// （Shift 追加框选）必须一眼看得出哪个是"已经在选中的"、哪个是"正在拉的"。
    static let marqueeDash: [CGFloat] = [4, 3]

    /// 最小外框边长（世界单位）。
    ///
    /// 拖到 0 会把元素弄丢——它还在场景里、还占着素材，但既看不见也点不中，
    /// 对用户来说等于删了却还能在库里找到，是最难自查的一类状态。
    static let minimumSide: CGFloat = 16

    /// 四个角手柄。
    ///
    /// 边手柄（上下左右）本轮不做：画布上的元素都是图片，等比缩放是默认，
    /// 拉单边的用途小于它带来的"什么时候能拉边"的困惑。要加时在这里加两个
    /// case 并补 `handleCenters` / `resized` 两个 switch——编译器会指出所有遗漏点。
    enum Handle: CaseIterable, Equatable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight

        /// 拖动这个手柄时不动的那一角。
        var anchor: CGPoint {
            switch self {
            case .topLeft: CGPoint(x: 1, y: 1)          // 归一化：右下角
            case .topRight: CGPoint(x: 0, y: 1)         // 左下角
            case .bottomLeft: CGPoint(x: 1, y: 0)       // 右上角
            case .bottomRight: CGPoint(x: 0, y: 0)      // 左上角
            }
        }

        /// 手柄在这一角时，"新外框"的哪一条边由拖动决定。
        var isLeftEdge: Bool { self == .topLeft || self == .bottomLeft }
        var isTopEdge: Bool { self == .topLeft || self == .topRight }
    }

    // MARK: - 手柄位置与命中

    /// 四个手柄中心的视图坐标。
    static func handleCenters(of frame: CGRect, camera: CanvasCamera) -> [Handle: CGPoint] {
        let view = camera.worldToView(frame)
        return [
            .topLeft: CGPoint(x: view.minX, y: view.minY),
            .topRight: CGPoint(x: view.maxX, y: view.minY),
            .bottomLeft: CGPoint(x: view.minX, y: view.maxY),
            .bottomRight: CGPoint(x: view.maxX, y: view.maxY),
        ]
    }

    /// 点中哪个手柄。`viewPoint` 是视图坐标。
    ///
    /// 外框很小时相邻手柄的命中区会重叠，此时先到先得（`Handle.allCases` 的顺序）。
    /// 不做"按离得最近的那个算"：那种实现的边界行为在重叠区里会随手指抖动
    /// 在两个手柄之间跳，表现是"拖着拖着换了一个角"。
    static func handle(
        at viewPoint: CGPoint,
        of frame: CGRect,
        camera: CanvasCamera
    ) -> Handle? {
        let side = handleSize + handleHitSlop * 2
        for (handle, center) in handleCenters(of: frame, camera: camera) {
            let hit = CGRect(
                x: center.x - side / 2,
                y: center.y - side / 2,
                width: side,
                height: side
            )
            if hit.contains(viewPoint) { return handle }
        }
        return nil
    }

    // MARK: - 缩放

    /// 拖某个手柄之后的**新外框**。锚点是对角，固定不动。
    ///
    /// - Parameter proportional: `true` 等比。产品负责人 2026-09-18 定的默认是
    ///   **等比**（图片永不变形），按住 Shift 走自由拉伸。两个方向都要有人用，
    ///   所以这条是参数而不是写死的分支。
    ///
    /// 拖过头（拖到锚点另一侧）**不翻转**，而是停在最小边长上：翻转会让图片
    /// 变成镜像，而镜像在画布上没有任何视觉提示，看起来就是"图坏了"。
    static func resized(
        _ frame: CGRect,
        handle: Handle,
        to worldPoint: CGPoint,
        proportional: Bool
    ) -> CGRect {
        let anchor = CGPoint(
            x: frame.minX + frame.width * handle.anchor.x,
            y: frame.minY + frame.height * handle.anchor.y
        )
        let width = max(abs(worldPoint.x - anchor.x), 0)
        let height = max(abs(worldPoint.y - anchor.y), 0)

        let newSize: CGSize
        if proportional, frame.width > 0, frame.height > 0 {
            // 取两个方向里"走得更远"的那个当比例：用单一轴会让另一个方向的手感
            // 显得迟钝，用几何平均则两个方向都发木。这是各家画布工具的通行做法。
            let scale = max(width / frame.width, height / frame.height)
            let size = CGSize(width: frame.width * scale, height: frame.height * scale)
            newSize = clampedToMinimum(size, aspect: frame.size)
        } else {
            newSize = CGSize(
                width: max(width, minimumSide),
                height: max(height, minimumSide)
            )
        }

        let origin = CGPoint(
            x: handle.isLeftEdge ? anchor.x - newSize.width : anchor.x,
            y: handle.isTopEdge ? anchor.y - newSize.height : anchor.y
        )
        return CGRect(origin: origin, size: newSize)
    }

    /// 等比缩放到最小边长以下时，**两个方向一起**顶住下限——只顶一个方向会破坏等比，
    /// 而等比正是这个分支存在的理由。
    private static func clampedToMinimum(_ size: CGSize, aspect: CGSize) -> CGSize {
        guard aspect.width > 0, aspect.height > 0 else {
            return CGSize(width: minimumSide, height: minimumSide)
        }
        let floor = max(minimumSide / aspect.width, minimumSide / aspect.height)
        let current = max(size.width / aspect.width, size.height / aspect.height)
        let scale = max(floor, current)
        return CGSize(width: aspect.width * scale, height: aspect.height * scale)
    }

    // MARK: - 框选

    /// 两个世界点之间的矩形（已标准化，可给 `CGRect.contains` / `intersects` 用）。
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }
}
