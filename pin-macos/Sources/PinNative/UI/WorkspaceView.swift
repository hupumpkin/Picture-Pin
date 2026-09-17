import SwiftUI

/// 工作台主界面。
///
/// ```text
/// ┌────┬─────────────────────────────────────────┐
/// │ 来 │ ┌──────────┐                            │
/// │ 源 │ │ 素材面板 │   画布（AppKit + CALayer） │
/// │ 栏 │ │ （浮层） │                            │
/// │    │ └──────────┘        ┌──────────────┐    │
/// │    │                     │   工具条     │    │
/// └────┴─────────────────────┴──────────────┴────┘
/// ```
///
/// ## 画布是基底，不是中间的一栏
///
/// 第一版是 `HStack{来源栏, 素材面板, 画布}`——画布被挤到右侧，只拿到剩下的宽度。
/// 那读起来是"三个并排的栏"，而不是"一张画布，上面浮着工具"。现在画布铺满
/// 来源栏右侧的**全部**区域，素材面板与工具条都是浮在它上面的层。
///
/// 这不是审美偏好，有两个具体后果：
///
/// 1. **画布宽度不再受面板影响。** 开关面板时画布尺寸不变，相机不用重新适配，
///    视口里的内容不会跟着跳一下。
/// 2. **浮层必须能收到点击，而这件事只能测。** 画布是 AppKit 的 NSView，
///    在 AppKit 的命中测试里它排在 SwiftUI 画出来的内容前面——浮层会不会被它
///    整个吞掉（表现是按钮点了没反应、反而平移了画布），读代码判断不了。
///    自检里 `floatingLayerReceivesClicks()` 就是钉这件事的。
///
/// 来源栏保持实色贴边（Pin Web 原型如此）：它是导航不是浮层，而且贴着窗口边
/// 那一条正是拖拽区。
struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @State private var panelWidth = DesignTokens.Metrics.panelWidth

    /// 浮层占掉的横向空间（面板可见时）。
    ///
    /// 工具条用它把中心让到**看得见的那块画布**上。不让的话，面板拖宽之后
    /// 工具条右半边会压在面板下面——两块玻璃叠在同一层，既难看又挡点击。
    private var floatingPanelOccupiedWidth: CGFloat {
        guard model.isMaterialPanelVisible else { return 0 }
        return panelWidth + DesignTokens.Metrics.floatingPanelInset * 2
    }

    var body: some View {
        HStack(spacing: 0) {
            SourceRail(sources: model.materialSources, selection: $model.activeSourceID)

            canvasArea
                .overlay(alignment: .leading) {
                    if model.isMaterialPanelVisible {
                        MaterialPanel(source: model.activeSource, width: $panelWidth)
                            .padding(DesignTokens.Metrics.floatingPanelInset)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
        }
        .frame(minWidth: 960, minHeight: 620)
        .animation(.easeOut(duration: 0.18), value: model.isMaterialPanelVisible)
    }

    private var canvasArea: some View {
        CanvasHostView(
            camera: model.camera,
            scene: model.scene,
            selection: model.selection,
            configuration: model.motionConfiguration,
            images: model.images,
            commands: model.commands,
            onSceneChange: { model.applyScene(fromCanvas: $0) },
            onSelectionChange: { model.applySelection(fromCanvas: $0) },
            onCameraChange: { model.camera = $0 }
        )
        .overlay(alignment: .bottom) {
            bottomRow
        }
        .overlay(alignment: .top) {
            if let message = model.storageError {
                StorageErrorBanner(message: message) { model.prepareStorage() }
                    .padding(.top, DesignTokens.Spacing.loose)
            }
        }
    }

    /// 画布底部的一行：工具条 +（空画布时的）操作引导。
    ///
    /// ## 为什么是把两者放进一个 `HStack`，而不是各自 `overlay` 一次
    ///
    /// 各自浮是 Pin Web 原型的写法（`.canvas-placeholder-toolbar{left:50%}` 加一个
    /// 绝对定位在右下的提示），代价是**两边都不知道对方有多宽**，只能靠一个
    /// "窗口窄于 1050px 就把提示藏起来"的媒体查询兜着——那个阈值是拍的，
    /// 而且面板拖宽之后它就不准了（面板吃掉的是同一块地方）。
    ///
    /// 放进同一个 `HStack` 之后，不重叠是**结构决定的**，不是量出来的。
    ///
    /// ## 提示为什么要放两份，其中一份还是隐藏的
    ///
    /// 第一版只把提示挂在工具条右边，结果**工具条并不在画布正中**：`HStack` 让
    /// 工具条在"扣掉提示之后剩下的空间"里居中，于是它比画布中心偏左半个提示宽。
    /// 实测（1280 宽、面板 240）：工具条中心 688pt，画布中心 812pt——124pt 的偏差，
    /// 一眼看得出来，而当时的注释里还写着"居中在看得见的画布上"。注释是错的，
    /// 布局也是错的，两个都改。
    ///
    /// 左边再放一份 `.hidden()` 的同款提示当**占位**，两边等宽，工具条就正好落在
    /// 行中心；占位用的是同一个视图，宽度不可能和右边那份走散。
    ///
    /// ## `ViewThatFits` 是这里唯一的"窄了就退让"
    ///
    /// 两份提示把工具条夹在中间，窗口很窄时会溢出（面板拖宽更早）。退让的条件
    /// 由 SwiftUI 按**真实宽度**算，不是再拍一个阈值：放不下就整条丢掉提示，
    /// 只剩居中的工具条。原型那个 1050 就是这样被替掉的——它替不掉的是
    /// "面板拖宽了还算不算数"，而这里"放不放得下"是当场量的。
    private var bottomRow: some View {
        ViewThatFits(in: .horizontal) {
            // 首选：提示 + 对称占位，工具条落在画布正中。
            if showsNavigationHint {
                HStack(spacing: DesignTokens.Spacing.regular) {
                    // 占位那份在可访问性上也得消失：它对用户根本不存在，却和右边
                    // 那份是同一个视图，同一句话会被读两遍。`.hidden()` 负不负责
                    // 把视图移出可访问性树，我在自检里验证不了（读不到 VoiceOver
                    // 的输出），所以显式声明一次——这一行不改布局，占位宽度照旧。
                    navigationHint.hidden().accessibilityHidden(true)
                    canvasToolbar
                    navigationHint
                }
            }
            // 次选：放不下就丢提示。工具条仍然居中，也绝不会溢出窗口。
            canvasToolbar
        }
        .padding(.leading, floatingPanelOccupiedWidth)
        .padding(.bottom, DesignTokens.Metrics.toolbarBottomInset)
    }

    /// 工具条本体。居中靠 `.frame(maxWidth: .infinity)`，这里只负责内容和接线。
    private var canvasToolbar: some View {
        CanvasToolbar(
            model: model,
            onZoomIn: { model.commands.zoomStep?(model.motionConfiguration.feel.zoomStepFactor) },
            onZoomOut: { model.commands.zoomStep?(1 / model.motionConfiguration.feel.zoomStepFactor) },
            onZoomReset: { model.commands.zoomTo?(1) },
            onFocusContent: { model.commands.focusContent?() }
        )
        .opacity(model.commands.isAttached ? 1 : 0)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 空画布的引导什么时候显示。
    ///
    /// 有元素后由场景驱动消失。出错横幅显示时也让位：数据目录建不出来的时候，
    /// "滚轮平移"这类引导本来就是噪音——先让用户看见出了什么事。
    private var showsNavigationHint: Bool {
        model.scene.elements.isEmpty && model.storageError == nil
    }

    // 位置从左下角挪到了右下角：面板浮上来之后，左下角正是被面板压住的地方。
    // Pin Web 原型本来也是在右下角（`right:14px; bottom:13px`）。
    private var navigationHint: some View {
        Text("滚轮平移 · 双指捏合缩放 · 拖拽画布移动")
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Surface.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, DesignTokens.Spacing.regular)
            .padding(.vertical, DesignTokens.Spacing.compact)
            .glassSurface(cornerRadius: DesignTokens.Radius.medium)
            .allowsHitTesting(false)
            .padding(.trailing, DesignTokens.Spacing.loose)
    }
}

/// 数据目录建立失败的提示。
///
/// 这条横幅存在的理由不是"错误处理要完整"，而是**这类失败在空库阶段完全无害，
/// 所以很容易被忽略**——等到导入图片、保存画布时才表现为「界面正常、数据不落盘」，
/// 那时排查要绕很大一圈。宁可现在就红着脸摆在画布上方。
private struct StorageErrorBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.compact) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: DesignTokens.Icon.inline))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.hairline) {
                Text("数据目录无法创建")
                    .font(DesignTokens.Typography.panelTitle)
                Text(message)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Surface.secondaryText)
                    .lineLimit(2)
            }
            Button("重试", action: onRetry)
                .controlSize(.small)
        }
        .padding(.horizontal, DesignTokens.Spacing.regular)
        .padding(.vertical, DesignTokens.Spacing.compact)
        .glassSurface(cornerRadius: DesignTokens.Radius.medium)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("数据目录无法创建：\(message)")
    }
}

extension CanvasToolbar {
    // 缩放步进倍数**不在这里**：它是手感参数，搬到了
    // `MotionConfiguration.Feel.zoomStepFactor`。放在工具栏类型上意味着
    // "只有点按钮才用得到它"，而菜单 `⌘=` / `⌘-` 和将来的调参窗口要读同一个值——
    // 三处各存一份迟早会不一致。
}
