import SwiftUI

/// 导入的状态胶囊（§3.6）：工具栏导入按钮按下之后，画布底部浮出一条
/// "正在导入…"，完成后换成"已导入 N 张（，M 张被拒：原因）"，几秒后自己消失。
///
/// 它只吃 `ImportFeedback`，不读 outcomes 字典、不认识导入协调器——
/// 内容怎么来的在 `WorkspaceView` 的接线里，这里只管把状态画出来。
///
/// 为什么不是模态弹窗也不是常驻横幅：导入是一次性的短暂动作，结果一句话
/// 就说得完。常驻横幅会把"数据目录坏了"这种需要人处理的事和"刚导完 3 张"
/// 混在同一层级里，用户分不清哪个要管。
struct ImportStatusToast: View {
    let feedback: ImportFeedback
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.compact) {
            leadingIcon
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.hairline) {
                Text(statusLine)
                    .font(DesignTokens.Typography.caption)
                if let failure = failureLine {
                    Text(failure)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Surface.secondaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.regular)
        .padding(.vertical, DesignTokens.Spacing.compact)
        .glassSurface(cornerRadius: DesignTokens.Radius.medium)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([statusLine, failureLine].compactMap { $0 }.joined(separator: "，"))
        // 结果几秒后自己消失。用 `.task(id:)` 而不是 `DispatchQueue.asyncAfter`：
        // 新状态进来会取消旧的计时（连按两次导入不会让上一次的结果提前把
        // 这一次的顶掉）。`Task.isCancelled` 之后再调 onDismiss 的话，会把
        // 新状态的胶囊也一起关掉。
        .task(id: feedback) {
            // "剪贴板里没有图片"也要自己走：它同样是一次短暂动作的回执，
            // 留在屏幕上只会挡住画布。
            switch feedback {
            case .finished, .canvasSaveFailed, .nothingToPaste: break
            case .importing: return
            }
            // 精校留白：停留时长（现在 4 秒）与消失方式（现在直接消失）由
            // Codex 按面板整体节奏调；这里只保证"结果会自己走，不会常驻"。
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch feedback {
        case .importing:
            ProgressView()
                .controlSize(.small)
        case .finished(_, let rejected, _):
            Image(systemName: rejected == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: DesignTokens.Icon.inline))
                .foregroundStyle(rejected == 0 ? DesignTokens.Surface.success : DesignTokens.Surface.warning)
        case .canvasSaveFailed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: DesignTokens.Icon.inline))
                .foregroundStyle(DesignTokens.Surface.warning)
        case .nothingToPaste:
            // 不是失败——用户只是在一张没有图的剪贴板上按了粘贴。用信息图标，
            // 不用警告三角：那会让人以为是自己弄坏了什么。
            Image(systemName: "info.circle.fill")
                .font(.system(size: DesignTokens.Icon.inline))
                .foregroundStyle(DesignTokens.Surface.secondaryText)
        }
    }

    private var statusLine: String {
        switch feedback {
        case .importing(let total):
            Copy.importing(total: total)
        case .finished(let imported, let rejected, _):
            rejected == 0 ? Copy.imported(imported) : Copy.importedWithRejected(imported, rejected)
        case .canvasSaveFailed(let stored, let rejected, _):
            "\(stored) 张已存入素材库，画布未保存\(rejected > 0 ? "；另有 \(rejected) 张被拒" : "")"
        case .nothingToPaste:
            Copy.nothingToPaste
        }
    }

    /// 第二行：第一条失败原因。失败原因只显示一条（`ImportFeedback.summary`
    /// 的取舍），数字承担"有几张"。
    private var failureLine: String? {
        switch feedback {
        case .canvasSaveFailed(_, _, let reason): return "请点击顶部“重试”：\(reason)"
        case .finished(_, let rejected, let firstFailure) where rejected > 0: return firstFailure
        default: return nil
        }
    }
}

extension ImportStatusToast {
    /// 导入提示的文案。改口径只改这里。
    private enum Copy {
        static func importing(total: Int) -> String { "正在导入 \(total) 张图片…" }
        static func imported(_ count: Int) -> String { "已导入 \(count) 张" }
        static func importedWithRejected(_ imported: Int, _ rejected: Int) -> String {
            "已导入 \(imported) 张，\(rejected) 张被拒"
        }
        /// 说清楚"剪贴板里没有图"，而不是"粘贴失败"：失败会让人去重试，
        /// 而这里重试多少次结果都一样，得先去复制一张图。
        static let nothingToPaste = "剪贴板里没有图片"
    }
}
