import Foundation

/// 一次导入批次的结果摘要（§3.6：工具栏按钮 → 提示胶囊）。
///
/// 与 `ImportCoordinator.FileOutcome` 之间做一次纯映射：界面不直接读 outcomes
/// 字典（那会让视图知道"库里发生了什么"的细节），只读这个摘要。它是纯值 +
/// 纯函数，自检直接断言，不依赖界面。
enum ImportFeedback: Equatable {
    case importing(total: Int)
    case finished(imported: Int, rejected: Int, firstFailure: String?)
    /// Bytes are in the material library, but their canvas placements are not durable yet.
    case canvasSaveFailed(stored: Int, rejected: Int, reason: String)

    /// 按了粘贴，但剪贴板里没有图片（§4 第 2 条）。
    ///
    /// **单独一支，不塞进 `finished(rejected: 1)`**：那不是"有东西被拒了"，
    /// 是"根本没有东西"。混进去的话提示会写成"已导入 0 张，1 张被拒"，
    /// 用户会回头去找那张并不存在的图到底怎么了。
    case nothingToPaste

    /// 把一批导入结果归纳成摘要。
    ///
    /// 「第一条失败」按 `urls` 的先后（用户选文件的先后）取，**不能**按字典
    /// 迭代序取：Swift Dictionary 不保证迭代顺序，同一批文件导两次，提示里的
    /// 第一条失败都可能不一样（实测同一批键的迭代序随进程哈希种子变）。自检
    /// `导入结果摘要（§3.6）` 第一版就是栽在这上面——两条断言随运行随机红。
    ///
    /// 失败文案取**第一条**：提示胶囊只有两行，全列出来只会被截断，
    /// 而"有几张被拒"这件事由数字承担。第一条之后的失败原因不会丢——
    /// 逐文件的完整结果在调用方（`model.importFiles` 的返回值）手里。
    ///
    /// `urls` 里没有的条目也计入总数（兜底循环）：调用方给错列表时，
    /// 宁可按某个顺序把数点全，也不能让"已导入 2 张"静默少报一张。
    static func summary(
        of outcomes: [URL: ImportCoordinator.FileOutcome],
        orderedBy urls: [URL]
    ) -> ImportFeedback {
        var imported = 0
        var rejected = 0
        var firstFailure: String?
        var storedWithoutCanvasSave = 0
        var saveFailure: String?
        for url in urls {
            guard let outcome = outcomes[url] else { continue }
            switch outcome {
            case .imported:
                imported += 1
            case .storedWithoutCanvasSave(_, let reason):
                storedWithoutCanvasSave += 1
                saveFailure = reason
            case .rejected(let rejection):
                rejected += 1
                if firstFailure == nil { firstFailure = rejection.message }
            }
        }
        let covered = Set(urls)
        for outcome in outcomes where !covered.contains(outcome.key) {
            switch outcome.value {
            case .imported:
                imported += 1
            case .storedWithoutCanvasSave(_, let reason):
                storedWithoutCanvasSave += 1
                saveFailure = reason
            case .rejected(let rejection):
                rejected += 1
                if firstFailure == nil { firstFailure = rejection.message }
            }
        }
        if let saveFailure {
            return .canvasSaveFailed(stored: storedWithoutCanvasSave, rejected: rejected,
                                     reason: saveFailure)
        }
        return .finished(imported: imported, rejected: rejected, firstFailure: firstFailure)
    }

    /// 粘贴那条通道的归纳。它没有 URL 列表可依（见
    /// `ImportCoordinator.importClipboard` 为什么返回数组），所以顺序就是
    /// 结果本来的顺序——**不能反过来按 `Set` 去重**：剪贴板里可以有同一个
    /// 文件的两次引用，那是两条结果。
    static func summary(of outcomes: [ImportCoordinator.FileOutcome]) -> ImportFeedback {
        guard !outcomes.isEmpty else { return .nothingToPaste }
        var imported = 0
        var rejected = 0
        var firstFailure: String?
        var storedWithoutCanvasSave = 0
        var saveFailure: String?
        for outcome in outcomes {
            switch outcome {
            case .imported:
                imported += 1
            case .storedWithoutCanvasSave(_, let reason):
                storedWithoutCanvasSave += 1
                saveFailure = reason
            case .rejected(let rejection):
                rejected += 1
                if firstFailure == nil { firstFailure = rejection.message }
            }
        }
        if let saveFailure {
            return .canvasSaveFailed(stored: storedWithoutCanvasSave, rejected: rejected,
                                     reason: saveFailure)
        }
        return .finished(imported: imported, rejected: rejected, firstFailure: firstFailure)
    }
}
