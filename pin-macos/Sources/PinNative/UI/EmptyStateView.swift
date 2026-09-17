import SwiftUI

/// 空状态。
///
/// 路线图 §6：原生版从全新空库开始，所以批次 A 的每一个面板**都会**显示空状态。
/// 这不是占位符，是这段时间里用户唯一能看到的真实界面，值得好好写：
/// 说清楚这里将来会出现什么，而不是一句「暂无数据」。
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.compact) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(DesignTokens.Surface.secondaryText)
                .padding(.bottom, DesignTokens.Spacing.hairline)
            Text(title)
                .font(DesignTokens.Typography.emptyStateTitle)
                .foregroundStyle(.primary)
            Text(message)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Surface.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DesignTokens.Spacing.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
