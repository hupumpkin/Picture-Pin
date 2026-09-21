import Foundation

/// 画布撤销历史的产品配置。
///
/// `UndoManager` 是窗口级对象，但“保留多少步”是画布体验的规则，集中在这里，
/// 避免日后要调容量时在宿主、菜单或控制器里寻找散落的数字。0 是 AppKit 的
/// “不设上限”，本产品默认只保留最近 15 个用户动作。
struct CanvasUndoConfiguration: Equatable, Sendable {
    var maximumSteps: Int

    init(maximumSteps: Int = 15) {
        precondition(maximumSteps >= 0, "撤销历史容量不能为负数")
        self.maximumSteps = maximumSteps
    }

    static let `default` = CanvasUndoConfiguration()
}
