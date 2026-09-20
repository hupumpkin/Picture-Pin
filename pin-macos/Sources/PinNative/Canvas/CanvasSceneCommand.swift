import CoreGraphics

/// 场景命令：输入层修改场景的**唯一**入口。
///
/// ## 为什么不让输入控制器直接改 `CanvasScene`
///
/// 场景有三个消费者——SwiftUI（`WorkspaceModel`）、渲染器、命中测试——它们必须
/// 看到同一版。输入控制器拿到的是 `context.scene` 的只读快照，自己改那份副本
/// 只会害了自己：SwiftUI 和渲染器都不会知道。所以改动必须交回宿主，
/// 由宿主一次性更新三处，这就是命令存在的理由。
///
/// 命令是值类型且 `Sendable`，因此可以在测试里直接构造、直接断言，
/// 不需要真实的鼠标事件。撤销不在命令里——撤销的粒度与合并策略属于
/// Codex 的 `SelectionController`（见 `CanvasContext.undoManager`）。
/// 「把这个元素的外框改成这个」。
///
/// 用具名结构体而不是 `(CanvasElementID, CGRect)` 元组：元组数组没有
/// 合成的 `Equatable`，而命令必须是可比较的（自检要断言"发出去的到底是哪一条"）。
struct CanvasElementFrame: Sendable, Equatable {
    var id: CanvasElementID
    var frame: CGRect
}

enum CanvasSceneCommand: Sendable, Equatable {
    /// 插入一个元素。`order` 由场景重新分配，调用方给的值会被覆盖。
    case insert(CanvasElement)
    /// 移除元素。**不删除素材**（路线图 §5）。
    case remove([CanvasElementID])
    /// 把元素放回它原来的位置与层序。删除的**逆操作**，撤销专用。
    ///
    /// 与 `insert` 的区别只有一条：**保留元素自带的 `order`**。删除的撤销
    /// 走 `insert` 的话，放回来的元素会排在所有人上面——撤销一次删除，
    /// 层序却变了，而"层序变了"在一堆叠起来的图上看起来就是另一张图。
    case restore([CanvasElement])
    /// 移动或缩放一个元素。直接操控走这条路径，立即生效、不加缓动。
    case setFrame(CGRect, for: CanvasElementID)
    /// 一次改一组元素的外框。多选拖动与多选缩放走这条。
    ///
    /// ## 为什么不是循环调用 `setFrame`
    ///
    /// 一次拖动是每帧一次改动。循环 N 个元素就是**每帧 N 次**场景变更，
    /// 而每次变更都要走完「场景 → 渲染器 → SwiftUI → 落库排队」整条路：
    /// 拖 20 个元素就是每帧 20 次 SwiftUI 更新。用一个命令带一组改动之后，
    /// 这三个消费者一帧只被通知一次。
    case setFrames([CanvasElementFrame])
    /// 把元素提到最前。
    case bringToFront([CanvasElementID])
}
