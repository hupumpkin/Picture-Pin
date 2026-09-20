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
        /// 面板能拖到多宽。取 900 是为了「沉浸式浏览网页」——420 那个上限
        /// 是按"读一个素材列表"定的，用来放一个网页太窄，页面的响应式布局会
        /// 一直停在手机版。
        ///
        /// 这只是**静态上限**。实际能拖到多宽还要看窗口：面板浮在画布上，
        /// 拖满就等于把画布藏起来了，见 `minVisibleCanvasWidth`。
        static let panelMaxWidth: CGFloat = 900

        /// 面板再宽，也要给画布留出这么一条。
        ///
        /// 面板是**浮在画布上**的，不是把画布挤开（见 `WorkspaceView` 的说明）。
        /// 不留这条的话，用户把面板拉到最宽会得到一块"没有画布"的界面——
        /// 而画布才是图要去的地方，他下一步就卡住了。
        ///
        /// 240 是照着底部工具条的宽度定的：工具条约 200pt，再窄它就会被
        /// `ViewThatFits` 丢掉提示、最后连自己都放不下。
        static let minVisibleCanvasWidth: CGFloat = 240

        /// 面板标题栏的高度。
        ///
        /// 它不只是"好看"：折叠按钮折叠前后要落在**同一个位置**，而这个高度
        /// 是那个位置的一部分（按钮在标题栏里垂直居中）。改这里，折叠后的
        /// 落点跟着变——两处都是从 `panelToggleTop` 算的，不会走散。
        static let panelHeaderHeight: CGFloat = 40

        /// 折叠/展开那枚方形按钮的边长。**折叠前后用同一个尺寸**，
        /// 不然两次点击的落点对不上。
        static let panelToggleSize: CGFloat = 28

        /// 折叠按钮相对**画布区域左上角**的横向偏移。
        ///
        /// 展开时它落在面板标题栏里（面板本身内缩 `floatingPanelInset`，
        /// 标题栏再内缩 `Spacing.regular`）；折叠时那一层不存在了，
        /// 就靠这两个常量把按钮放回原处。
        static var panelToggleLeading: CGFloat {
            floatingPanelInset + Spacing.regular
        }

        /// 折叠按钮相对画布区域顶边的纵向偏移。见 `panelToggleLeading`。
        static var panelToggleTop: CGFloat {
            floatingPanelInset + (panelHeaderHeight - panelToggleSize) / 2
        }
        static let toolbarHeight: CGFloat = 36
        /// 工具条距窗口底边的距离。浮在画布之上，不占画布高度。
        static let toolbarBottomInset: CGFloat = 16

        /// 面板内浏览器导航条（前进/后退/刷新 + 地址栏）的高度。
        /// 比画布工具条略高：里面装了 26pt 的图标按钮，还要留一点上下余地。
        static let browserToolbarHeight: CGFloat = 40

        /// 浮动面板到画布边缘的内缩。取 14 是照 Pin Web 原型的 `top/bottom/left: 14px`
        /// ——浮层贴着窗口边会读成"另一栏"，内缩之后才读成"浮在纸上的一张卡"。
        static let floatingPanelInset: CGFloat = 14

        /// 素材面板条目缩略图的边长（点）。解码目标按 `displayScale` 放大，
        /// 实际请求的像素尺寸由行视图算。
        static let materialThumbnailSize: CGFloat = 32

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

        /// 选中外框与变换手柄的描边。用**系统强调色**。
        ///
        /// 不自己挑一个蓝：macOS 上"这东西被选中了"就是这个颜色，Finder、
        /// 预览、备忘录一致；而且用户换强调色（比如换成红色）时，画布跟着变
        /// 才是对的。自定的蓝在红色强调色的系统上会跟整个界面打架。
        static let selectionBorder = Color(nsColor: .controlAccentColor)

        /// 变换手柄的填充。**刻意不跟随外观**：手柄贴在图片上，而图片可能是
        /// 任何颜色——白底 + 强调色描边是唯一在任意内容上都读得出来的组合。
        static let handleFill = Color(nsColor: .white)

        /// 框选矩形。填充很淡，压住下面的元素但仍看得见它们；
        /// 描边与选中框同色但不重合——正在拉的和已经选中的必须能分辨。
        static let marqueeFill = Color(nsColor: .controlAccentColor).opacity(0.12)
        static let marqueeBorder = Color(nsColor: .controlAccentColor)
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
        /// 成功与警告的语义色（§3.6：导入提示胶囊、失败横幅共用）。
        /// 语义色必须是同一套——"绿色对勾"在两个地方是两种绿的话，
        /// 用户会把它们读成两种状态。
        static let success = Color.green
        static let warning = Color.orange

        /// 界面层的强调色（拖入落点高亮等）。取系统强调色而不是写死一个蓝：
        /// 用户在系统设置里换过强调色之后，画布的选中框会跟着换
        /// （`Canvas.selectionBorder` 用的是同一个来源），面板的高亮却还是
        /// 原来那个蓝——两处本该是"同一种高亮"，看起来却像两种状态。
        static let accent = Color.accentColor
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
