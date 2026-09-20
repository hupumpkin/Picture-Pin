import CoreGraphics
import Foundation

/// 画布元素的稳定标识。跨会话持久化，所以是 UUID 而不是数组下标。
struct CanvasElementID: Hashable, Sendable, Codable {
    let raw: UUID
    init(_ raw: UUID = UUID()) { self.raw = raw }
    init?(string: String) { guard let uuid = UUID(uuidString: string) else { return nil }; self.raw = uuid }
}

/// 素材（导入的原图）标识。
///
/// 画布元素只**引用**素材，不拥有它：一张素材可以多次进入画布形成多个元素，
/// 移除元素不删除素材（路线图 §5 必测场景）。
struct AssetID: Hashable, Sendable, Codable {
    let raw: UUID
    init(_ raw: UUID = UUID()) { self.raw = raw }
    init?(string: String) { guard let uuid = UUID(uuidString: string) else { return nil }; self.raw = uuid }
}

/// 画布上的一个元素。
struct CanvasElement: Identifiable, Equatable, Sendable, Codable {
    enum Kind: Equatable, Sendable, Codable {
        /// 图片元素。`asset` 指向素材库中的原图。
        case image(asset: AssetID)
        // 文字元素属于后续阶段（路线图 §6），本轮不开放。
    }

    var id: CanvasElementID
    var kind: Kind
    /// 外框，**世界坐标**。旋转未开放，所以只有 origin 和 size 有意义。
    var frame: CGRect
    /// 绘制顺序，小的在下。
    var order: Int
}

/// 一次场景变更的结果。
///
/// 场景只描述"变了什么"，由调用方决定如何送到渲染器——这样场景本身不依赖
/// CALayer，也不需要知道有没有渲染器在监听（路线图 §2.2）。
///
/// **`order` 是自描述的**：产生变更的场景动作知道顺序有没有变，就顺手填上，
/// 调用方因此可以把一份 `CanvasSceneChange` 原样交给渲染器，不必自己再比一遍。
/// 手头只有新版场景、没有变更对象时，用 `CanvasScene.change(from:)` 反算。
struct CanvasSceneChange: Equatable, Sendable {
    var inserted: [CanvasElement] = []
    var updated: [CanvasElement] = []
    var removed: [CanvasElementID] = []
    /// 完整的绘制顺序。为 `nil` 表示顺序未变，渲染器可以跳过重排。
    var order: [CanvasElementID]?

    var isEmpty: Bool {
        inserted.isEmpty && updated.isEmpty && removed.isEmpty && order == nil
    }

    static let none = CanvasSceneChange()
}

/// 画布场景：元素集合的唯一真相来源。
///
/// 不依赖 CALayer，不含动画，不含选择状态——选择属于 Codex 的
/// `SelectionController`，撤销模型同样不属于这里（路线图 §2.2）。
///
/// 本轮只有一个默认画布，但模型保留 `boardID`，为后续多画布留出接口
/// （路线图 §6）。
struct CanvasScene: Equatable, Sendable {
    let boardID: UUID
    private(set) var elements: [CanvasElement]
    /// 每次结构变化递增，供渲染器判断是否需要全量重建。
    private(set) var revision: UInt64 = 0

    init(boardID: UUID = UUID(), elements: [CanvasElement] = []) {
        self.boardID = boardID
        self.elements = elements.sorted { $0.order < $1.order }
    }

    // MARK: - 查询

    var isEmpty: Bool { elements.isEmpty }

    func element(_ id: CanvasElementID) -> CanvasElement? {
        elements.first { $0.id == id }
    }

    /// 所有元素的联合外框。空场景返回 `.null`。
    var contentBounds: CGRect {
        elements.reduce(CGRect.null) { $0.union($1.frame) }
    }

    // MARK: - 场景动作（路线图 §4 规则 2 的接口冻结项之一）

    @discardableResult
    mutating func insert(_ element: CanvasElement) -> CanvasSceneChange {
        guard self.element(element.id) == nil else { return .none }
        var placed = element
        placed.order = nextOrder()
        elements.append(placed)
        elements.sort { $0.order < $1.order }
        revision += 1
        return CanvasSceneChange(inserted: [placed], order: elements.map(\.id))
    }

    @discardableResult
    mutating func insert(contentsOf newElements: [CanvasElement]) -> CanvasSceneChange {
        var change = CanvasSceneChange()
        for element in newElements where self.element(element.id) == nil {
            change.inserted.append(insert(element).inserted.first ?? element)
        }
        guard !change.isEmpty else { return .none }
        change.order = elements.map(\.id)
        return change
    }

    @discardableResult
    mutating func remove(_ ids: [CanvasElementID]) -> CanvasSceneChange {
        let target = Set(ids)
        let removed = elements.filter { target.contains($0.id) }
        guard !removed.isEmpty else { return .none }
        elements.removeAll { target.contains($0.id) }
        revision += 1
        // 移除画布元素**不删除素材**（路线图 §5）：这里只动元素集合。
        return CanvasSceneChange(removed: removed.map(\.id), order: elements.map(\.id))
    }

    /// 把元素放回它原来的位置与层序（删除的逆操作）。
    ///
    /// 与 `insert` 的唯一区别是**不重新分配 `order`**：撤销一次删除，
    /// 层序必须回到删除之前。已经在场景里的 id 跳过（幂等），
    /// 所以重复调用不会插出两份。
    @discardableResult
    mutating func restore(_ restored: [CanvasElement]) -> CanvasSceneChange {
        let missing = restored.filter { self.element($0.id) == nil }
        guard !missing.isEmpty else { return .none }
        elements.append(contentsOf: missing)
        elements.sort { $0.order < $1.order }
        revision += 1
        return CanvasSceneChange(inserted: missing, order: elements.map(\.id))
    }

    /// 移动或缩放一个元素。直接操控走这条路径，立即生效，不加缓动。
    @discardableResult
    mutating func setFrame(_ frame: CGRect, for id: CanvasElementID) -> CanvasSceneChange {
        guard let index = elements.firstIndex(where: { $0.id == id }) else { return .none }
        guard elements[index].frame != frame else { return .none }
        elements[index].frame = frame
        revision += 1
        return CanvasSceneChange(updated: [elements[index]])
    }

    /// 一次改一组元素的外框。多选拖动与多选缩放走这条。
    ///
    /// 与逐个 `setFrame` 的区别**只在通知次数**：这里产生**一份**变更，
    /// 三个消费者（渲染器、SwiftUI、落库排队）各被通知一次，而不是每个元素一次。
    /// 改动本身逐条判断，外框没变的不进 `updated`——"拖了但没动"不该产生噪音。
    @discardableResult
    mutating func setFrames(_ assignments: [CanvasElementFrame]) -> CanvasSceneChange {
        var change = CanvasSceneChange()
        for assignment in assignments {
            guard let index = elements.firstIndex(where: { $0.id == assignment.id }) else { continue }
            guard elements[index].frame != assignment.frame else { continue }
            elements[index].frame = assignment.frame
            change.updated.append(elements[index])
        }
        guard !change.isEmpty else { return .none }
        revision += 1
        // order 未变：只动外框。
        return change
    }

    /// 把元素提到最前。选择与拖拽的常见后续动作。
    @discardableResult
    mutating func bringToFront(_ ids: [CanvasElementID]) -> CanvasSceneChange {
        let target = Set(ids)
        guard elements.contains(where: { target.contains($0.id) }) else { return .none }
        var next = nextOrder()
        var updated: [CanvasElement] = []
        for index in elements.indices where target.contains(elements[index].id) {
            elements[index].order = next
            updated.append(elements[index])
            next += 1
        }
        elements.sort { $0.order < $1.order }
        revision += 1
        return CanvasSceneChange(updated: updated, order: elements.map(\.id))
    }

    private func nextOrder() -> Int {
        (elements.map(\.order).max() ?? -1) + 1
    }

    // MARK: - 场景差异

    /// 与上一版场景之间的完整差异。
    ///
    /// ## 这是「场景 → 渲染器」的唯一同步契约
    ///
    /// 宿主保存一份**已同步给渲染器的场景**，每次拿到新场景就用本函数反算差异。
    /// 之所以让宿主而不是渲染器来算：只有宿主同时握着新旧两版，渲染器手上那份
    /// 是它自己维护的内部状态，拿它当基准迟早会分叉。
    ///
    /// 做成纯函数是有意的——差异算错的表现是"某些元素死活不显示"，
    /// 这种 bug 靠肉眼要等到批次 B 往画布里放第一个元素时才会暴露。
    /// 纯函数可以直接在 `--selftest` 里构造两个场景对比，不需要建任何 CALayer。
    func change(from previous: CanvasScene) -> CanvasSceneChange {
        // 换了画布：旧元素全部作废，新元素全部重建，不做逐元素比对。
        //
        // 覆盖的是**两块画布存在同 ID 元素**这种情况——复制画布、跨画布移动元素
        // 会造出来。那时逐元素比对会把它们判成"没有变化"，两块画布的内容纠缠在
        // 一起。`sceneDiffIsComplete()` 里用同一个元素 ID 构造了这条断言。
        //
        // 单纯"换到另一块画布"用不着这个分支：元素 ID 是 UUID，两块画布的元素
        // 集合通常不相交，逐元素比对本就会得出同样的"全删全插"。也就是说
        // `boardSwitchReachesRenderer()` 那条端到端断言**抓不到这个分支的缺失**
        // ——注入缺陷实测：它全绿，红的是 `sceneDiffIsComplete()` 里的两条。
        guard boardID == previous.boardID else {
            return CanvasSceneChange(
                inserted: elements,
                removed: previous.elements.map(\.id),
                order: elements.map(\.id)
            )
        }

        let previousByID = Dictionary(
            previous.elements.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentIDs = Set(elements.map(\.id))

        var change = CanvasSceneChange()
        for element in elements {
            guard let old = previousByID[element.id] else {
                change.inserted.append(element)
                continue
            }
            // `CanvasElement` 整体比较，所以改外框、改 order 都会落到 updated。
            if old != element { change.updated.append(element) }
        }
        change.removed = previous.elements.map(\.id).filter { !currentIDs.contains($0) }

        // `elements` 始终按 order 升序，所以 id 序列就是绘制顺序。
        if elements.map(\.id) != previous.elements.map(\.id) {
            change.order = elements.map(\.id)
        }
        return change
    }
}
