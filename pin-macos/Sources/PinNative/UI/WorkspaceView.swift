import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    /// 面板外壳与工具条的手感参数。**微调改 `PanelChrome` 一处**，
    /// 不要在这里写数字。
    var chrome: PanelChrome = .default
    @State private var panelWidth = DesignTokens.Metrics.panelWidth
    /// 网页不能沿用列表的 260pt 默认值，否则会落进目标网站的移动布局。
    @State private var browserPanelWidth: CGFloat = 560
    @State private var showFileImporter = false
    @State private var importFeedback: ImportFeedback?
    /// 画布区域的实际宽度。只用来算面板能拖多宽，不参与任何布局。
    @State private var canvasAreaWidth: CGFloat = 0

    /// 浮层占掉的横向空间（面板可见时）。
    ///
    /// 工具条用它把中心让到**看得见的那块画布**上。不让的话，面板拖宽之后
    /// 工具条右半边会压在面板下面——两块玻璃叠在同一层，既难看又挡点击。
    private var floatingPanelOccupiedWidth: CGFloat {
        guard model.isMaterialPanelVisible else { return 0 }
        return activePanelWidth.wrappedValue + DesignTokens.Metrics.floatingPanelInset * 2
    }

    private var activePanelWidth: Binding<CGFloat> {
        Binding(
            get: { model.activeSource.surface == .browser ? browserPanelWidth : panelWidth },
            set: { newValue in
                if model.activeSource.surface == .browser {
                    browserPanelWidth = newValue
                } else {
                    panelWidth = newValue
                }
            }
        )
    }

    /// 宽度还没量出来时（第一帧）退回静态上限：那一帧面板还在按默认宽度布局，
    /// 用户不可能正拖着把手。
    private var availablePanelMaxWidth: CGFloat {
        PanelWidthPolicy.maximum(canvasAreaWidth: canvasAreaWidth)
    }

    var body: some View {
        HStack(spacing: 0) {
            SourceRail(sources: model.materialSources, selection: $model.activeSourceID)

            canvasArea
                // 量画布区域的宽度，用来算面板能拖多宽。放 `background` 里
                // 而不是包一层 `GeometryReader`：`GeometryReader` 会**吃掉**
                // 父级给的建议尺寸、让子视图塌成它自己的理想尺寸，而这一层
                // 正是"画布铺满剩余区域"的实现。
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { canvasAreaWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, width in
                                canvasAreaWidth = width
                            }
                    }
                }
                .overlay(alignment: .leading) { materialPanel }
                .overlay(alignment: .topLeading) { collapsedPanelButton }
        }
        .frame(minWidth: 960, minHeight: 620)
        .animation(chrome.collapseAnimation, value: model.isMaterialPanelVisible)
        .animation(.easeOut(duration: 0.18), value: importFeedback)
        .fileImporter(
            isPresented: $showFileImporter,
            // The importer uses ImageIO bytes, not the filename's UTType, to decide.
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            importFiles(urls, origin: .fileImport)
        }
        .sheet(item: $model.svgEditingDocument) { document in
            SVGEditorSheet(document: document) { updated in
                Task { _ = await model.saveSVGEditing(updated) }
            }
        }
    }

    /// 素材面板本体。
    ///
    /// **折叠时是"从视图树上摘掉"，不是"藏起来"。** 网页不会因此被销毁——
    /// 它归 `WebBrowserModel` 所有（见那里的说明），视图只是把同一张网页挂进
    /// 挂出。所以折叠再展开不会重新加载，也不用重新登录。
    @ViewBuilder private var materialPanel: some View {
        if model.isMaterialPanelVisible {
            MaterialPanel(
                source: model.activeSource,
                width: activePanelWidth,
                maxWidth: availablePanelMaxWidth,
                onToggleCollapse: { model.isMaterialPanelVisible = false },
                browser: model.activeSource.surface == .browser ? model.webBrowser : nil,
                onPasteFromBrowser: { pasteFromClipboard() },
                onDropFiles: { urls in
                    // 面板上的落点只入库、不摆画布（见 `onDropFiles`
                    // 的说明）。导入结果照样走同一条提示胶囊。
                    importFiles(urls, origin: .dragIn, placingOnCanvas: false)
                }
            )
            .padding(DesignTokens.Metrics.floatingPanelInset)
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    /// 折叠之后留在原处的那枚方形按钮。
    ///
    /// ## 位置必须和标题栏里那颗**重合**
    ///
    /// 展开时按钮在 `MaterialPanel` 的标题栏里；折叠时那一层整个不存在了，
    /// 这里按同一组常量（`panelToggleLeading` / `panelToggleTop`）把**同一个**
    /// `PanelToggleButton` 放回原处。两处读的是同一组数，改一处两边一起动。
    ///
    /// 位置选在这里而不是窗口别处，是因为收起之后用户的视线**还在面板原来
    /// 在的地方**：那里什么都没有的话，"怎么找回来"要重新找一遍。
    /// 工具条上那个入口已经拿掉了，这里不留就真的没有就近的入口。
    @ViewBuilder private var collapsedPanelButton: some View {
        if !model.isMaterialPanelVisible {
            PanelToggleButton(isCollapsed: true) {
                model.isMaterialPanelVisible = true
            }
            .padding(.leading, DesignTokens.Metrics.panelToggleLeading)
            .padding(.top, DesignTokens.Metrics.panelToggleTop)
            .transition(.opacity)
        }
    }

    // MARK: - 三条采集通道的接线
    //
    // 选择器、拖入、粘贴都汇到这一处，因为三者发给用户的回执是同一条提示胶囊
    // （§3.6）。各自 `Task { … }` 一遍的话，最容易漏的是"失败也要说话"——
    // 一条通道静默失败，用户看到的就是"拖进去了但什么都没发生"。

    /// 走一次文件导入，并把提示胶囊接上。
    ///
    /// - Returns: **收不收**，不是"导没导成"。拖入那条通道必须当场回答
    ///   （`performDragOperation` 是同步方法），所以这里只判断有没有活可干，
    ///   结果由胶囊事后汇报——失败也绝不会静默。
    @discardableResult
    private func importFiles(
        _ urls: [URL],
        origin: AssetRecord.Origin,
        placingOnCanvas: Bool = true,
        anchor: CGPoint? = nil
    ) -> Bool {
        guard !urls.isEmpty else { return false }
        Task {
            importFeedback = .importing(total: urls.count)
            let outcomes = await model.importFiles(
                urls, origin: origin, placingOnCanvas: placingOnCanvas, anchor: anchor
            )
            importFeedback = ImportFeedback.summary(of: outcomes, orderedBy: urls)
        }
        return true
    }

    /// ⌘V。**不显示"正在导入"**：绝大多数 ⌘V 的结果是"剪贴板里没有图片"，
    /// 先闪一下"正在导入"再改口，看起来像出了什么错。
    private func pasteFromClipboard() {
        Task {
            importFeedback = await model.paste()
        }
    }

    /// 一批**已经读出来**的载荷进画布（§4 第 1 条）。
    ///
    /// 走的是粘贴那条流水线（`model.importPayload`），只有两处不同：来源记
    /// `.dragIn`，落点用光标位置。**不显示"正在导入"**的理由和 ⌘V 一样——
    /// 拖进来一张不是图片的东西时，先闪一下再改口会读成"出了什么错"。
    @discardableResult
    private func importPayload(
        _ payload: ClipboardPayload,
        origin: AssetRecord.Origin,
        anchor: CGPoint?
    ) -> Bool {
        guard !payload.isEmpty else { return false }
        Task {
            importFeedback = await model.importPayload(payload, origin: origin, anchor: anchor)
        }
        return true
    }

    private var canvasArea: some View {
        CanvasHostView(
            camera: model.camera,
            scene: model.scene,
            selection: model.selection,
            tool: model.canvasTool,
            showsGrid: model.showsCanvasGrid,
            configuration: model.motionConfiguration,
            images: model.images,
            commands: model.commands,
            onSceneChange: { model.applyScene(fromCanvas: $0) },
            onSelectionChange: { model.applySelection(fromCanvas: $0) },
            onCameraChange: { model.camera = $0 },
            onDrop: { payload, worldPoint in
                // 落点交给导入协调器：用户把图拖到哪儿，它就该出现在哪儿。
                importPayload(payload, origin: .dragIn, anchor: worldPoint)
            },
            onPaste: { pasteFromClipboard() },
            canEditSVG: { elementID in model.canEditSVGElement(elementID) },
            onEditSVG: { elementID in model.beginEditingSVGElement(elementID) }
        )
        .overlay(alignment: .bottom) {
            bottomRow
        }
        .overlay(alignment: .bottom) {
            // 导入状态胶囊（§3.6）。垫在工具条**上方**（工具条高 + 底距），
            // 水平方向和工具条一样让开面板占掉的空间。
            if let feedback = importFeedback {
                ImportStatusToast(feedback: feedback) {
                    importFeedback = nil
                }
                .padding(.leading, floatingPanelOccupiedWidth)
                .padding(.bottom, DesignTokens.Metrics.toolbarBottomInset
                    + DesignTokens.Metrics.toolbarHeight
                    + DesignTokens.Spacing.compact)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            // 两条横幅互斥：隔离成功的路径上 `storageError` 是空的，
            // 而 `storageError` 非空时根本没走到隔离那一步。
            if let message = model.storageError {
                // Reuse pending writes after a save failure; on first-open failure,
                // reopen and restore before accepting imports.
                StorageErrorBanner(message: message) {
                    Task { await model.recoverStorage() }
                }
                .padding(.top, DesignTokens.Spacing.loose)
            } else if let quarantine = model.quarantine {
                LibraryQuarantineBanner(
                    quarantine: quarantine,
                    onExport: { exportDiagnostics() },
                    onReveal: {
                        NSWorkspace.shared.activateFileViewerSelecting([quarantine.destination])
                    }
                )
                .padding(.top, DesignTokens.Spacing.loose)
            }
        }
    }

    /// 把诊断存成文件（C2 §4 第 4 条）。
    ///
    /// **用 `NSSavePanel`，不替用户挑目录**：这份文件的用途是拿出去求助，
    /// 存进一个应用自己选的目录（既看不见也说不清在哪儿）等于没导出。
    private func exportDiagnostics() {
        Task {
            guard let text = await model.diagnosticsText() else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Pin 诊断 \(LibraryRecovery.timestamp(Date())).txt"
            panel.allowedContentTypes = [.plainText]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                // 写不出去要说出来：用户以为诊断存好了、拿着一个不存在的路径去找人，
                // 比一开始就没导出更糟。
                model.reportStorageError("诊断没写出去：\(error.localizedDescription)")
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

    /// 底部这一行横向还剩多少点（已经扣掉面板占掉的）。
    ///
    /// 工具条按它决定收起几个图标。**只用这一个数**驱动收起，不再另设阈值：
    /// 宽度变了就多收或少收一格，两者是同一个量的单调函数，不会互相追。
    private var bottomRowAvailableWidth: CGFloat {
        max(0, canvasAreaWidth - floatingPanelOccupiedWidth)
    }

    /// 工具条本体。居中靠 `.frame(maxWidth: .infinity)`，这里只负责内容和接线。
    private var canvasToolbar: some View {
        CanvasToolbar(
            model: model,
            availableWidth: bottomRowAvailableWidth,
            chrome: chrome,
            onZoomIn: { model.commands.zoomStep?(model.motionConfiguration.feel.zoomStepFactor) },
            onZoomOut: { model.commands.zoomStep?(1 / model.motionConfiguration.feel.zoomStepFactor) },
            onZoomTo: { model.commands.zoomTo?($0) },
            onFocusContent: { model.commands.focusContent?() },
            onFocusSelection: { model.commands.focusSelection?() },
            onImport: { showFileImporter = true },
            isImportEnabled: !isImporting
        )
        .opacity(model.commands.isAttached ? 1 : 0)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 导入进行中。进行中时禁用导入按钮，防止两批导入叠在一起。
    private var isImporting: Bool {
        if case .importing = importFeedback { return true }
        return false
    }

    /// 空画布的引导什么时候显示。
    ///
    /// 有元素后由场景驱动消失。出错横幅显示时也让位：数据目录建不出来的时候，
    /// "滚轮平移"这类引导本来就是噪音——先让用户看见出了什么事。
    ///
    /// 隔离横幅同理，而且这里的"让位"是**字面意思**：新库是空的，
    /// `elements.isEmpty` 一定成立，所以不让的话两条会同时出现——
    /// 一条说"你的库被搬走了"，另一条说"滚轮可以平移画布"。
    private var showsNavigationHint: Bool {
        model.scene.elements.isEmpty && model.storageError == nil && model.quarantine == nil
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
                .foregroundStyle(DesignTokens.Surface.warning)
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

/// 库被隔离之后的警告条（C2 §4 第 4 条）。
///
/// ## 它和上面那条不是同一件事
///
/// `StorageErrorBanner` 说的是"**这一次**没准备好"——重试是有意义的。
/// 这条说的是"**你原来那份数据被搬走了**，现在界面上这个库是新建的空库"。
/// 重试解决不了它，而且它说的正是用户最怕的那件事（"我的素材没了"），
/// 所以三件事必须同时说清：
///
/// 1. **没有被删除**——原文标题里的"已改名保留"就是为这一句；
/// 2. **在哪儿**——路径要能看见，还要有一个按钮直接带他过去；
/// 3. **怎么办**——导出诊断，那是他找人看或者自己重放的全部材料。
///
/// **不自动消失，也不给"知道了"**：这是启动时的一次性判断，用户很可能正好
/// 没看见屏幕；而关掉之后界面里没有任何其他地方再提这件事。
private struct LibraryQuarantineBanner: View {
    let quarantine: LibraryQuarantine
    let onExport: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.compact) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: DesignTokens.Icon.inline))
                .foregroundStyle(DesignTokens.Surface.warning)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.hairline) {
                Text("原来的素材库打不开，已改名保留")
                    .font(DesignTokens.Typography.panelTitle)
                Text("现在显示的是一个新建的空库。原来的数据没有被删除，改名后的文件是：")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Surface.secondaryText)
                Text(quarantine.destination.path)
                    .font(DesignTokens.Typography.caption.monospaced())
                    .foregroundStyle(DesignTokens.Surface.secondaryText)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Button("在访达中显示", action: onReveal)
                .controlSize(.small)
            Button("导出诊断", action: onExport)
                .controlSize(.small)
        }
        .padding(.horizontal, DesignTokens.Spacing.regular)
        .padding(.vertical, DesignTokens.Spacing.compact)
        .glassSurface(cornerRadius: DesignTokens.Radius.medium)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("原来的素材库打不开，已改名保留在 \(quarantine.destination.path)")
    }
}

extension CanvasToolbar {
    // 缩放步进倍数**不在这里**：它是手感参数，搬到了
    // `MotionConfiguration.Feel.zoomStepFactor`。放在工具栏类型上意味着
    // "只有点按钮才用得到它"，而菜单 `⌘=` / `⌘-` 和将来的调参窗口要读同一个值——
    // 三处各存一份迟早会不一致。
}
