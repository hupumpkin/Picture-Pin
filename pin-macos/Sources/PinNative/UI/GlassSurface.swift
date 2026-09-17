import SwiftUI

/// Liquid Glass 表面的统一封装（macOS 26）。
///
/// 之所以包一层：`glassEffect` 的签名在系统更新里动过，集中在一处改比散在
/// 十几个视图里改便宜得多。同时这里也是「什么时候用玻璃、什么时候用实色」这条
/// 规则的落点——浮在画布之上的控件用玻璃，贴着窗口边缘的固定区域用实色
/// （玻璃叠在纯色上是纯浪费，还更容易在浅色画布上糊成一片）。
extension View {

    /// 浮动控件：工具条、浮动面板。
    ///
    /// **玻璃是背景，不是滤镜。** 直接写 `.glassEffect()` 会把玻璃作用在内容上，
    /// 容器最外侧的子视图会被冲成白色——工具条最左（定位内容）和最右（面板开关）
    /// 两个按钮在浅色模式下直接消失，中间的放大镜却完好无损。改成放在
    /// `.background` 里之后，控件与玻璃成了兄弟关系而不是父子关系，
    /// 绘制顺序清楚，也不会被玻璃的合成规则挑挑拣拣。
    func glassSurface(cornerRadius: CGFloat = DesignTokens.Radius.panel) -> some View {
        background {
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }

    /// 可交互的浮动控件。悬停与按下由系统绘制，不再自己写高亮。
    func interactiveGlassSurface(cornerRadius: CGFloat = DesignTokens.Radius.medium) -> some View {
        background {
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        }
    }

    /// 浮动面板的表面：玻璃 + 圆角裁剪 + 描边 + 投影。
    ///
    /// 比 `glassSurface()` 多三件事，每一件都有理由：
    ///
    /// - **圆角裁剪**：玻璃自己有圆角，但**里面的内容没有**——面板里是 `ScrollView`，
    ///   滚动时列表会从圆角处露出一块直角，像贴纸没裁齐。
    /// - **描边**：纯玻璃的边缘在浅色画布上几乎看不出边界，面板会"没有形状"。
    /// - **投影**：这是"浮"这件事唯一的视觉依据。没有投影就只是一块半透明色，
    ///   读起来仍然是分栏。Pin Web 原型用的也是 `0 8px 24px` 这一档。
    ///
    /// 裁剪只作用于**面板内容**：调用点在裁剪之后才挂调整宽度的把手，
    /// 免得那半个越界的命中区被一起切掉。
    func floatingPanelSurface(cornerRadius: CGFloat = DesignTokens.Radius.panel) -> some View {
        background {
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(DesignTokens.Surface.floatingPanelBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
    }
}

/// 工具条内的一枚按钮。
///
/// 图标用 SF Symbols，尺寸走 `DesignTokens.Icon`。这里只管外观与命中区域，
/// 具体动作由调用方给。
struct ToolbarIconButton: View {
    let systemImage: String
    let help: String
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                // 必须显式指定单色渲染。工具条装在 Liquid Glass 容器里，而玻璃会给
                // 内容套上 vibrancy；像 `sidebar.left` 这种带填充层的符号会因此解析出
                // 白色前景——在浅色画布上几乎看不见，而旁边的 `plus.magnifyingglass`
                // 却是正常黑色。同一个按钮、只换符号名就出现这种差异，很难从代码上看
                // 出来，只能靠截图。单色模式把这条不确定性掐掉。
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                .font(.system(size: DesignTokens.Icon.toolbar, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                .fill(Color.primary.opacity(isHovering && isEnabled ? 0.08 : 0))
        }
        .onHover { isHovering = $0 }
        .help(help)
        // 路线图 §3.1 要求「图标操作有 tooltip 和可访问名称」。tooltip 是 `.help`，
        // 可访问名称是这个——纯图标按钮在 VoiceOver 里否则只是个「按钮」。
        .accessibilityLabel(help)
    }
}
