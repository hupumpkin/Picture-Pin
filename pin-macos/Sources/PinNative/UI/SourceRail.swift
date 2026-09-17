import SwiftUI

/// 最左侧的来源栏。窄条，左侧是品牌标记，下面是来源图标，靠 tooltip 说明。
///
/// ## 这个视图不认识任何具体来源
///
/// 它遍历传进来的来源数组，每个按钮的图标和名字都从 `MaterialSource` 上读。
/// 第一版这里有一个 `enum MaterialSource` 加一个 `switch` 算图标，
/// 结果是"加一个来源"必须打开这个文件。现在加来源只改 catalog 一处。
///
/// 列表由**传参**进来而不是视图自己去查目录：目录是从 `AppEnvironment` 建出来的
/// （素材提供者要拿数据目录），视图不该知道这件事。
struct SourceRail: View {
    let sources: [MaterialSource]
    @Binding var selection: MaterialSourceID

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.compact) {
            brandMark

            Rectangle()
                .fill(DesignTokens.Surface.separator)
                .frame(width: 22, height: 1)
                .padding(.bottom, DesignTokens.Spacing.hairline)

            ForEach(sources) { source in
                RailButton(
                    source: source,
                    isSelected: selection == source.id,
                    action: { selection = source.id }
                )
            }
            Spacer()
        }
        .padding(.vertical, DesignTokens.Spacing.regular)
        .frame(width: DesignTokens.Metrics.sourceRailWidth)
        .frame(maxHeight: .infinity)
        .background(DesignTokens.Surface.rail)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(DesignTokens.Surface.separator)
                .frame(width: 1)
        }
    }

    /// 品牌标记（路线图 §3.1 要求来源栏有清楚层级）。
    ///
    /// 用图钉而不是字母缩写：产品叫 Pin，图钉就是它的名字，比自造一个字母组合
    /// 更好认。上面一条分隔线把它和来源图标分开——分隔线是必需的，
    /// 否则它会读成「第四个来源按钮」而不是标记。
    private var brandMark: some View {
        VStack(spacing: DesignTokens.Spacing.hairline) {
            Image(systemName: "pin.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("Pin")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.Surface.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pin")
        .accessibilityAddTraits(.isHeader)
        .help("Pin")
    }
}

private struct RailButton: View {
    let source: MaterialSource
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: source.systemImage)
                .font(.system(size: DesignTokens.Icon.rail, weight: .regular))
                .frame(width: 36, height: 36)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
                        .fill(background)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(source.title)
        .accessibilityLabel(source.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.14) }
        return isHovering ? Color.primary.opacity(0.06) : .clear
    }
}
