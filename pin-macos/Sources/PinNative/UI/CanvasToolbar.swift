import SwiftUI

/// 浮在画布底部的工具条。
///
/// 用 Liquid Glass 而不是实色条：它压在画布之上，底下的网格应该透出来，
/// 用户才会感觉画布是连续的、工具条是「浮在纸上的」。占满宽度会切断这种连续感，
/// 所以它是按内容宽度居中的胶囊。
///
/// 批次 A 只有视图控制（缩放、定位内容、面板开关）。对齐、分布、成组这些
/// 需要选中项的工具，等批次 B 有选择模型之后再进来。
struct CanvasToolbar: View {
    let model: WorkspaceModel
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void
    let onZoomReset: () -> Void
    let onFocusContent: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: DesignTokens.Spacing.compact) {
            HStack(spacing: DesignTokens.Spacing.tight) {
                ToolbarIconButton(
                    // 用箭头而不是某个「框」类符号：15pt 下框类符号会糊成一团，
                    // 箭头在同样尺寸下轮廓依然清楚。
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    help: "定位到全部内容",
                    isEnabled: !model.scene.elements.isEmpty,
                    action: onFocusContent
                )

                divider

                ToolbarIconButton(
                    systemImage: "minus.magnifyingglass",
                    help: "缩小",
                    isEnabled: model.camera.zoom > CanvasCamera.minZoom,
                    action: onZoomOut
                )

                Button(action: onZoomReset) {
                    Text(model.zoomPercentText)
                        .font(DesignTokens.Typography.numeric)
                        // 宽度固定，否则 9% → 100% 会让整条工具栏左右跳动。
                        .frame(width: 46)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("恢复 100%")
                .accessibilityLabel("缩放比例")
                .accessibilityValue(model.zoomPercentText)

                ToolbarIconButton(
                    systemImage: "plus.magnifyingglass",
                    help: "放大",
                    isEnabled: model.camera.zoom < CanvasCamera.maxZoom,
                    action: onZoomIn
                )

                divider

                ToolbarIconButton(
                    systemImage: "sidebar.left",
                    help: model.isMaterialPanelVisible ? "隐藏素材面板" : "显示素材面板",
                    action: { model.isMaterialPanelVisible.toggle() }
                )
            }
            .padding(.horizontal, DesignTokens.Spacing.compact)
            .frame(height: DesignTokens.Metrics.toolbarHeight)
            .glassSurface()
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 16)
    }
}
