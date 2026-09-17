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
enum CanvasSceneCommand: Sendable, Equatable {
    /// 插入一个元素。`order` 由场景重新分配，调用方给的值会被覆盖。
    case insert(CanvasElement)
    /// 移除元素。**不删除素材**（路线图 §5）。
    case remove([CanvasElementID])
    /// 移动或缩放一个元素。直接操控走这条路径，立即生效、不加缓动。
    case setFrame(CGRect, for: CanvasElementID)
    /// 把元素提到最前。
    case bringToFront([CanvasElementID])
}
