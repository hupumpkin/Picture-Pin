import SwiftUI

/// The compact canvas controls stay above the canvas, without resizing it.
///
/// ## 宽度不够时从右往左逐个收起
///
/// 面板拖宽会挤压工具条。第一版的处理是 `ViewThatFits` 整条丢/不丢，于是
/// 挤压到阈值附近时两种布局来回翻，看起来在抽搐。现在改成**逐格退让**：
/// 可用宽度每少一格就少一个图标（见 `ToolbarSlot.visible`），宽度变化是单调的，
/// 不存在"哪种布局"这回事。
///
/// 收起顺序、每一格占多宽、最少留几个，全部在 `PanelChrome.Toolbar` 里，
/// 不在这里写死。
struct CanvasToolbar: View {
    @Bindable var model: WorkspaceModel
    /// 底部这一行横向可用多少点（已经扣掉面板占掉的那一块）。
    let availableWidth: CGFloat
    var chrome: PanelChrome = .default
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void
    let onZoomTo: (CGFloat) -> Void
    let onFocusContent: () -> Void
    let onFocusSelection: () -> Void
    let onImport: () -> Void
    let isImportEnabled: Bool

    private var visibleSlots: [ToolbarSlot] {
        ToolbarSlot.visible(availableWidth: availableWidth, chrome: chrome.toolbar)
    }

    var body: some View {
        HStack(spacing: chrome.toolbar.spacing) {
            ForEach(visibleSlots, id: \.self) { slot in
                slotView(slot)
            }
        }
        .padding(.horizontal, chrome.toolbar.horizontalPadding / 2)
        .frame(height: DesignTokens.Metrics.toolbarHeight)
        .background(DesignTokens.Surface.panel, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
                .strokeBorder(DesignTokens.Surface.floatingPanelBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        // 收起的动画挂在 `visibleSlots` 上：它一变，`ForEach` 里被去掉的那个
        // 条目按默认过渡淡出，右边的条目跟着左移。
        .animation(chrome.toolbarAnimation, value: visibleSlots)
    }

    /// 一个条目长什么样。**分派集中在这一处**，增删条目只动
    /// `ToolbarSlot` 和这里两个地方。
    @ViewBuilder private func slotView(_ slot: ToolbarSlot) -> some View {
        switch slot {
        case .selectTool:
            toolButton(.cursor, "选择", tool: .select)
        case .handTool:
            toolButton(.hand, "抓手", tool: .hand)
        case .dividerAfterTools, .dividerAfterImport, .dividerAfterFocus, .dividerAfterZoom:
            divider
        case .importImage:
            iconButton(.imageAdd, "导入图片", enabled: isImportEnabled, action: onImport)
        case .focusAll:
            iconButton(.focusAll, "定位到全部内容",
                       enabled: !model.scene.elements.isEmpty, action: onFocusContent)
        case .focusSelection:
            iconButton(.focusSelection, "定位到选中内容",
                       enabled: !model.selection.isEmpty, action: onFocusSelection)
        case .zoomOut:
            iconButton(.zoomOut, "缩小",
                       enabled: model.camera.zoom > CanvasCamera.minZoom, action: onZoomOut)
        case .zoomLevel:
            CanvasToolbarZoomMenu(value: model.zoomPercentText, onZoomTo: onZoomTo, metrics: chrome.toolbar)
        case .zoomIn:
            iconButton(.zoomIn, "放大",
                       enabled: model.camera.zoom < CanvasCamera.maxZoom, action: onZoomIn)
        case .grid:
            iconButton(.grid, model.showsCanvasGrid ? "隐藏网格" : "显示网格",
                       selected: model.showsCanvasGrid) {
                model.showsCanvasGrid.toggle()
            }
        }
    }

    private func toolButton(_ symbol: RemixIcon.Symbol, _ label: String, tool: CanvasTool) -> some View {
        iconButton(symbol, label, selected: model.canvasTool == tool) {
            model.canvasTool = tool
        }
    }

    private func iconButton(
        _ symbol: RemixIcon.Symbol,
        _ label: String,
        enabled: Bool = true,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        CanvasToolbarIconButton(
            symbol: symbol,
            label: label,
            isEnabled: enabled,
            isSelected: selected,
            metrics: chrome.toolbar,
            action: action
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: chrome.toolbar.dividerWidth, height: 16)
    }
}

/// The disabled state uses a semantic label colour rather than transparency:
/// it remains sharp against the solid toolbar, while still communicating that there is
/// no eligible canvas content or selection yet.
private struct CanvasToolbarIconButton: View {
    let symbol: RemixIcon.Symbol
    let label: String
    let isEnabled: Bool
    let isSelected: Bool
    let metrics: PanelChrome.Toolbar
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            RemixIcon(symbol: symbol)
                .frame(width: metrics.iconWidth, height: metrics.iconWidth)
                .contentShape(.rect)
        }
        .buttonStyle(CanvasToolbarIconButtonStyle(
            isEnabled: isEnabled,
            isSelected: isSelected,
            isHovering: isHovering,
            animationDuration: metrics.duration
        ))
        .disabled(!isEnabled)
        .onHover { isHovering = isEnabled && $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct CanvasToolbarIconButtonStyle: ButtonStyle {
    let isEnabled: Bool
    let isSelected: Bool
    let isHovering: Bool
    let animationDuration: TimeInterval

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed && isEnabled
        configuration.label
            .foregroundStyle(foreground)
            .background(background(isPressed: isPressed), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
                }
            }
            .scaleEffect(isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: animationDuration), value: isHovering)
            .animation(.easeOut(duration: animationDuration), value: isPressed)
    }

    private var foreground: Color {
        if !isEnabled { return Color.secondary }
        return isSelected ? .accentColor : .primary
    }

    private func background(isPressed: Bool) -> Color {
        if isSelected {
            return Color.accentColor.opacity(isPressed ? 0.24 : 0.15)
        }
        if isHovering {
            return Color.primary.opacity(isPressed ? 0.13 : 0.08)
        }
        return .clear
    }
}

private struct CanvasToolbarZoomMenu: View {
    let value: String
    let onZoomTo: (CGFloat) -> Void
    let metrics: PanelChrome.Toolbar

    @State private var isHovering = false

    var body: some View {
        Menu {
            ForEach([25, 50, 100, 200, 400], id: \.self) { percent in
                Button("\(percent)%") { onZoomTo(CGFloat(percent) / 100) }
            }
        } label: {
            Text(value)
                .font(DesignTokens.Typography.numeric)
                .foregroundStyle(Color.primary)
                .frame(width: metrics.zoomMenuWidth, height: metrics.iconWidth)
                .background(
                    isHovering ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .onHover { isHovering = $0 }
        .help("选择缩放比例")
        .accessibilityLabel("缩放比例")
        .accessibilityValue(value)
    }
}
