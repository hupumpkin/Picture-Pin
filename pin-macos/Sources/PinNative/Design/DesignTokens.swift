import SwiftUI

/// 设计令牌：间距、圆角、字号、图标尺寸、配色的唯一来源。
///
/// 路线图 §3.1 要求「公共规则集中管理」。这里的每一条都是**跨界面复用**的规则；
/// 只在某一个视图里出现一次的数值应该留在那个视图里，不要为了统一而搬进来
/// ——令牌表变成杂物间之后，就没人愿意遵守它了。
enum DesignTokens {

    /// 间距梯度。界面里只用这六个值，不出现 7、13、18 这类随手写的数。
    enum Spacing {
        static let hairline: CGFloat = 2
        static let tight: CGFloat = 4
        static let compact: CGFloat = 8
        static let regular: CGFloat = 12
        static let loose: CGFloat = 16
        static let section: CGFloat = 24
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
        /// 面板与工具条：macOS 26 的 Liquid Glass 容器使用较大圆角。
        static let panel: CGFloat = 18
    }

    enum Typography {
        static let panelTitle = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13)
        static let caption = Font.system(size: 11)
        /// 缩放百分比、尺寸读数等数值：等宽，避免数字跳动时布局抖动。
        static let numeric = Font.system(size: 11, design: .monospaced)
        static let emptyStateTitle = Font.system(size: 15, weight: .medium)
    }

    enum Icon {
        static let toolbar: CGFloat = 15
        static let rail: CGFloat = 18
        static let inline: CGFloat = 11
    }

    enum Metrics {
        static let sourceRailWidth: CGFloat = 56
        static let panelWidth: CGFloat = 260
        static let panelMinWidth: CGFloat = 200
        static let panelMaxWidth: CGFloat = 420
        static let toolbarHeight: CGFloat = 36
        /// 工具条距窗口底边的距离。浮在画布之上，不占画布高度。
        static let toolbarBottomInset: CGFloat = 16

        /// 浮动面板到画布边缘的内缩。取 14 是照 Pin Web 原型的 `top/bottom/left: 14px`
        /// ——浮层贴着窗口边会读成"另一栏"，内缩之后才读成"浮在纸上的一张卡"。
        static let floatingPanelInset: CGFloat = 14

    }

    /// 画布配色。深色模式下画布不是纯黑——画布是「纸」，不是「背景」，
    /// 保持一点点亮度才能让元素的边缘阴影有地方落。
    enum Canvas {
        static let background = Color(
            light: NSColor(calibratedWhite: 0.957, alpha: 1),
            dark: NSColor(calibratedWhite: 0.129, alpha: 1)
        )
        static let gridLine = Color(
            light: NSColor(calibratedWhite: 0.902, alpha: 1),
            dark: NSColor(calibratedWhite: 0.196, alpha: 1)
        )
        static let originMark = Color(
            light: NSColor(calibratedWhite: 0.780, alpha: 1),
            dark: NSColor(calibratedWhite: 0.310, alpha: 1)
        )
    }

    /// 界面配色。目前只覆盖批次 A 用到的几处，其余等真正用到时再加。
    ///
    /// 深浅两套必须保持**同一个明暗次序**：来源栏最暗、画布居中、素材面板最亮。
    /// 浅色模式下「越亮越靠前」，深色模式同理——第一版把深色的来源栏写成比面板亮，
    /// 结果 rail 在深色下浮到了最前面，层次正好反过来。改一层明度很容易，
    /// 改错次序只有把两种外观并排看才发现。
    enum Surface {
        static let rail = Color(
            light: NSColor(calibratedWhite: 0.933, alpha: 1),
            dark: NSColor(calibratedWhite: 0.110, alpha: 1)
        )
        static let panel = Color(
            light: NSColor(calibratedWhite: 0.976, alpha: 1),
            dark: NSColor(calibratedWhite: 0.157, alpha: 1)
        )
        /// 浮动面板的描边。玻璃边缘没有线会糊在画布上，看不出边界。
    static let floatingPanelBorder = Color(
        light: NSColor(calibratedWhite: 0, alpha: 0.10),
        dark: NSColor(calibratedWhite: 1, alpha: 0.14)
    )

    static let separator = Color(
            light: NSColor(calibratedWhite: 0.859, alpha: 1),
            dark: NSColor(calibratedWhite: 0.235, alpha: 1)
        )
        static let secondaryText = Color(
            light: NSColor(calibratedWhite: 0.451, alpha: 1),
            dark: NSColor(calibratedWhite: 0.612, alpha: 1)
        )
    }
}

private extension Color {
    /// 一个色值同时给出浅色与深色两版，避免调用处到处写
    /// `colorScheme == .dark ? a : b`。
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        })
    }
}
