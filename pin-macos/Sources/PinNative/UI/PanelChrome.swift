import CoreGraphics
import Foundation
import SwiftUI

/// 面板外壳与底部工具条的布局、动效参数。
///
/// ## 为什么集中在一处
///
/// 和 `MotionConfiguration.Feel` 同一个理由：这些数字散在视图里之后，
/// 调一次手感要全项目搜 `0.18`，而搜索本身不可靠——`0.18` 这种数字到处都是。
/// 收拢之后，微调改这一个结构体。
///
/// 产品负责人 2026-09-20 明确说这批数值要后期微调，所以每个字段都注明了
/// 它影响什么、往哪个方向改会怎样。
struct PanelChrome: Equatable, Sendable {

    /// 面板展开/收起的时长，单位秒。
    var collapseDuration: TimeInterval
    var collapseCurve: MotionCurve

    /// 底部工具条在空间不够时怎么退让。见 `Toolbar`。
    var toolbar: Toolbar

    /// 工具条退让：**从右往左逐个收起**，最少只剩最左边那一个。
    ///
    /// ## 为什么不是"整体隐藏"或者"整体缩小"
    ///
    /// 第一版用的是 `ViewThatFits` 的整条丢/不丢，于是面板拖宽挤压工具条时
    /// 会出现"整条工具条闪一下"的抽搐——两种布局在阈值两侧来回翻。
    /// 逐个收起之后，宽度变化是**单调**的：每多挤掉一格，少一个图标，
    /// 不存在"哪种布局"这回事。
    struct Toolbar: Equatable, Sendable {

        /// 图标按钮的宽度（正方形边长）。
        var iconWidth: CGFloat

        /// 缩放比例菜单的宽度。它比图标宽（里面是"100%"这样的文字）。
        var zoomMenuWidth: CGFloat

        /// 竖分隔线的宽度。
        var dividerWidth: CGFloat

        /// 相邻条目之间的间距。
        var spacing: CGFloat

        /// 工具条自身的横向内边距（左右各一份）。
        var horizontalPadding: CGFloat

        /// **至少保留几个条目。** 1 = 只剩最左边那一个。
        ///
        /// 取 1 而不是 0：工具条整个消失之后，用户就再也没有入口切工具、
        /// 定位内容或者导入图片了——那是"退让"过头，不是"适配"。
        var minimumVisibleSlots: Int

        /// 收起/展开的时长与曲线。
        ///
        /// 比面板展开收起**快**：它跟随的是拖拽的实时挤压，慢半拍会看起来
        /// 像在追鼠标。
        var duration: TimeInterval
        var curve: MotionCurve

        /// 一个条目占掉的横向空间：自身宽度 + 它后面那一份间距。
        func cost(of slot: ToolbarSlot) -> CGFloat {
            switch slot {
            case .zoomLevel: zoomMenuWidth + spacing
            case .dividerAfterTools, .dividerAfterImport, .dividerAfterFocus, .dividerAfterZoom:
                dividerWidth + spacing
            default: iconWidth + spacing
            }
        }
    }

    static let `default` = PanelChrome(
        collapseDuration: 0.18,
        collapseCurve: .easeOut,
        toolbar: Toolbar(
            iconWidth: 28,
            zoomMenuWidth: 52,
            dividerWidth: 1,
            spacing: DesignTokens.Spacing.tight,
            horizontalPadding: DesignTokens.Spacing.compact * 2,
            minimumVisibleSlots: 1,
            duration: 0.12,
            curve: .easeOut
        )
    )

    /// 面板展开 / 收起。
    var collapseAnimation: Animation { Self.animation(collapseDuration, collapseCurve) }

    /// 工具条逐格收起。
    var toolbarAnimation: Animation { Self.animation(toolbar.duration, toolbar.curve) }

    private static func animation(_ duration: TimeInterval, _ curve: MotionCurve) -> Animation {
        switch curve {
        case .linear: .linear(duration: duration)
        case .easeIn: .easeIn(duration: duration)
        case .easeOut: .easeOut(duration: duration)
        case .easeInOut: .easeInOut(duration: duration)
        }
    }
}

/// 折叠 / 展开素材面板的那枚方形按钮。
///
/// **展开和折叠两种状态共用这一个视图**，尺寸也只从
/// `Metrics.panelToggleSize` 来——两处落点要重合，任何一边单独改尺寸都会让
/// 它们错开，而错开的表现是"点起来像没反应"。位置同理，两边都从
/// `panelToggleLeading` / `panelToggleTop` 算。
///
/// 唯一按状态变的是**底色**：展开时它待在面板标题栏里（背后已经是面板的表面），
/// 折叠时它孤零零浮在画布上，没有底色就看不出边界、也点不出"这里有个按钮"。
struct PanelToggleButton: View {
    let isCollapsed: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            RemixIcon(symbol: .sidebar)
                .frame(
                    width: DesignTokens.Metrics.panelToggleSize,
                    height: DesignTokens.Metrics.panelToggleSize
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
        }
        .modifier(CollapsedGlassSurface(isCollapsed: isCollapsed))
        .onHover { isHovering = $0 }
        .help(isCollapsed ? "展开素材面板" : "收起素材面板")
        .accessibilityLabel(isCollapsed ? "展开素材面板" : "收起素材面板")
    }
}

/// 折叠态才加玻璃底。展开态不加是**故意的**：那时候它已经在面板这张玻璃卡
/// 里面了，再叠一层会在标题栏上糊出一块深浅不一的方块。
private struct CollapsedGlassSurface: ViewModifier {
    let isCollapsed: Bool

    func body(content: Content) -> some View {
        if isCollapsed {
            content.interactiveGlassSurface(cornerRadius: DesignTokens.Radius.medium)
        } else {
            content
        }
    }
}

/// 底部工具条上的一个条目。
///
/// **声明顺序就是从右往左收起的倒序**：空间不够时从数组末尾往前丢，
/// 所以数组前面的是"撑到最后才消失"的。产品负责人要的"最少剩左侧第一个图标"
/// 就是这个顺序的第一个元素。
///
/// 分隔线也占一格。丢的时候如果末尾正好是一条分隔线，它会被顺手去掉——
/// 一条悬在右端、后面什么都没有的竖线读起来像渲染错误。
enum ToolbarSlot: Hashable, CaseIterable {
    case selectTool
    case handTool
    case dividerAfterTools
    case importImage
    case dividerAfterImport
    case focusAll
    case focusSelection
    case dividerAfterFocus
    case zoomOut
    case zoomLevel
    case zoomIn
    case dividerAfterZoom
    case grid

    var isDivider: Bool {
        switch self {
        case .dividerAfterTools, .dividerAfterImport, .dividerAfterFocus, .dividerAfterZoom: true
        default: false
        }
    }

    /// 给定可用宽度，从左往右数出放得下的部分。
    ///
    /// - 至少留 `minimumVisibleSlots` 个（**第一个永远保留**，哪怕它自己就超出
    ///   可用宽度：工具条整个消失比溢出更糟，用户会失去所有入口）；
    /// - 末尾的分隔线顺手去掉。
    static func visible(
        availableWidth: CGFloat, chrome: PanelChrome.Toolbar
    ) -> [ToolbarSlot] {
        var visible: [ToolbarSlot] = []
        if availableWidth > 0 {
            let usable = availableWidth - chrome.horizontalPadding * 2
            var used: CGFloat = 0
            for slot in allCases {
                let cost = chrome.cost(of: slot)
                // 第一个无条件留下：见上面那条。
                if !visible.isEmpty, used + cost > usable { break }
                used += cost
                visible.append(slot)
            }
        } else {
            // 宽度还没量出来（第一帧）：全给，别让工具条先闪一下空的。
            visible = allCases
        }

        let minimum = max(1, chrome.minimumVisibleSlots)
        if visible.count < minimum {
            visible = Array(allCases.prefix(minimum))
        }
        while visible.count > minimum, visible.last?.isDivider == true {
            visible.removeLast()
        }
        return visible
    }
}

/// 面板能拖到多宽。
///
/// ## 为什么不是设计令牌里的一个常量
///
/// 面板是**浮在画布上**的，不是把画布挤开（见 `WorkspaceView` 的说明）。
/// 一个固定上限认不得窗口有多大：在 1280 的窗口上拖到 900 还剩一块画布，
/// 在 960 的窗口上同样拖到 900 就只剩一条缝——用户下一步要把图拖到画布上，
/// 而画布已经没了。
///
/// 拉成纯函数是为了能直接断言：这类"算错就少一块地方"的几何，按选择几何
/// 那条规矩先在纯函数上钉死，比在界面上量便宜得多。
enum PanelWidthPolicy {

    /// 画布区域宽 `canvasAreaWidth` 时，面板最多能拖到多少。
    ///
    /// - 静态上限 `panelMaxWidth` 封顶（沉浸式浏览需要的宽度）；
    /// - 再按可用宽度收一道，保证留得下 `minVisibleCanvasWidth`；
    /// - **下限是 `panelMinWidth`**：窗口被拉得极窄时会算出比最小宽度还小的
    ///   值，而 `200...180` 这样的区间是崩，不是钳制。宽度还没量出来
    ///   （`0`）时退回静态上限。
    static func maximum(canvasAreaWidth: CGFloat) -> CGFloat {
        guard canvasAreaWidth > 0 else { return DesignTokens.Metrics.panelMaxWidth }
        let usable = canvasAreaWidth - DesignTokens.Metrics.floatingPanelInset * 2
        return max(
            DesignTokens.Metrics.panelMinWidth,
            min(DesignTokens.Metrics.panelMaxWidth, usable - DesignTokens.Metrics.minVisibleCanvasWidth)
        )
    }
}
