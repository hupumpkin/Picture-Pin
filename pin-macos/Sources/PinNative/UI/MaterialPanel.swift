import SwiftUI

/// 素材面板。列出当前来源下的素材，并支持拖到画布。
///
/// ## 这个视图也不认识任何具体来源
///
/// 第一版这里有两处 `switch source`（空状态标题、空状态说明），加一个来源就要
/// 打开这个文件改文案。现在两行文案从 `MaterialSource` 上读，面板只认三个东西：
/// **来源的描述**、**内容提供者的状态**、**内容的形态**。
///
/// 面板因此也不认识"内容是怎么来的"。批次 C 换上真实提供者时，
/// 这里一行都不用改——本批次的面板已经在跑真实的状态机了（见 `MaterialSourceContent`）。
///
/// 素材读取与拖拽属于批次 C（路线图 §5）。面板宽度可拖拽调整，
/// 与 Pin Web 的 P0.3.1 行为对齐。
struct MaterialPanel: View {
    let source: MaterialSource
    @Binding var width: CGFloat
    /// 这块窗口下**实际**能拖到多宽。由 `WorkspaceView` 按可用宽度算好传进来——
    /// 静态上限（`panelMaxWidth`）不认得窗口有多大，而面板浮在画布上，
    /// 拖满就等于把画布藏起来。见 `DesignTokens.Metrics.minVisibleCanvasWidth`。
    let maxWidth: CGFloat
    /// 收起面板。按钮在标题栏里（见 `header`），动作由外面给——
    /// 展开/收起是 `WorkspaceModel` 的状态，面板不自己改。
    let onToggleCollapse: () -> Void
    /// 内嵌浏览面的状态。**由模型层传进来，面板不自己建**：
    /// 面板被折叠或切走来源时 SwiftUI 会拆掉这个视图，自己建的话网页会跟着
    /// 被销毁，再展开就是重新加载、重新登录（见 `WebBrowserModel`）。
    let browser: WebBrowserModel?
    /// 网页获得焦点时，标准 ⌘V 仍交给网页；这条闭包提供不依赖焦点的采集入口。
    let onPasteFromBrowser: () -> Void
    /// 文件被拖到面板上（§4 第 1 条）。**只入库，不摆画布**——用户把图拖到
    /// 素材面板上是"收进素材库"，不是"放到画布上"；要摆上画布得拖到画布上。
    /// 这个区别在别处也一样：Figma 的图层栏、Finder 的侧边栏都是这个语义。
    let onDropFiles: ([URL]) -> Bool

    @State private var dragStartWidth: CGFloat?
    /// 拖动悬停在面板上。**必须给反馈**：没有它，用户拖到面板上时
    /// 完全不知道这里收不收（面板长得和平时一模一样）。
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DesignTokens.Surface.separator)
            content
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        // 整块面板可命中：玻璃背景本身不接点击（`fill(.clear)` 是命中透明的），
        // 而面板的内容可以很稀疏——转圈、失败提示、空状态都是中间一小块。
        // 没有这一行，点面板空白处会穿透到画布、变成平移画布（§3.4 起
        // 真实提供者让"转圈/失败"成了真实可达的状态，这条才被走到）。
        .contentShape(Rectangle())
        // 浮在画布上的一张玻璃卡：圆角、描边、投影（见 `floatingPanelSurface`）。
        // 第一版是 `.background(实色)` 且贴着窗口左边——那读起来是"中间那一栏"，
        // 画布被它切成两半，而不是"画布上浮着一张卡"。
        .floatingPanelSurface()
        // 把手挂在裁剪**之后**：它的命中区比可见的 1pt 宽得多，有一半在面板外，
        // 先裁的话那半个命中区会被切掉，拖起来只有一半灵。
        .overlay(alignment: .trailing) { resizeHandle }
        // 高亮也挂在这一层（和把手同一层），跟着面板的圆角走。
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.medium, style: .continuous)
                    .strokeBorder(DesignTokens.Surface.accent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        // 拖入落点（§4 第 1 条）。用 SwiftUI 的 `.dropDestination`：面板是
        // 纯 SwiftUI 的，没有 AppKit 视图可以接（画布那边是 NSViewRepresentable，
        // 走的是 `NSDraggingDestination`，见 `CanvasHostNSView`）。
        .dropDestination(for: URL.self) { urls, _ in
            onDropFiles(urls.filter(\.isFileURL))
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        // 切换来源时拉一次。重复调用是安全的——`refresh()` 约定为幂等。
        .task(id: source.id) {
            await source.provider.refresh()
        }
    }

    /// 标题栏。
    ///
    /// ## 折叠按钮为什么在这里，不在工具条上
    ///
    /// 它控制的是**这个面板**，贴着自己的标题最说得通；放在底部工具条上，
    /// 那个开关和工具、缩放、网格混在一排，读起来像另一类操作。
    ///
    /// 更要紧的是**折叠前后按钮落在同一个位置**：展开时它在这里，
    /// 折叠时那一层没了，`WorkspaceView` 按同一组常量（
    /// `Metrics.panelToggleLeading` / `panelToggleTop`）把同一枚按钮放回原处。
    /// 所以"收起来"和"点回来"是同一个动作落在同一个点上，鼠标不用找。
    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.tight) {
            PanelToggleButton(isCollapsed: false, action: onToggleCollapse)
            Text(source.title)
                .font(DesignTokens.Typography.panelTitle)
            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.regular)
        .frame(height: DesignTokens.Metrics.panelHeaderHeight)
    }

    // MARK: - 内容

    /// 按形态分派。新增形态时这里会编译不过，直到新形态被实现——
    /// 这是故意的：遗漏是编译错误，不是界面上一片空白。
    @ViewBuilder
    private var content: some View {
        switch source.surface {
        case .collection:
            collection
        case .browser:
            if let browser {
                WebBrowserPanel(model: browser, onPasteFromClipboard: onPasteFromBrowser)
            }
        }
    }

    @ViewBuilder
    private var collection: some View {
        switch source.provider.content {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let items) where items.isEmpty:
            EmptyStateView(
                systemImage: source.systemImage,
                title: source.emptyTitle,
                message: source.emptyMessage
            )

        case .loaded(let items):
            collectionList(items)

        case .failed(let message):
            failure(message)
        }
    }

    /// 条目列表。行视图只吃数据与取缩略图的方式（§3.6 的分层规则），
    /// 接线在这里：缩略图由**当前来源的提供者**回答——面板不自己拿
    /// `ImageProvider`，那会让面板认识具体来源。
    private func collectionList(_ items: [MaterialItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.Spacing.compact) {
                ForEach(items) { item in
                    MaterialItemRowView(item: item) { targetSize in
                        await source.provider.thumbnail(
                            for: item, targetPixelSize: targetSize
                        )
                    }
                }
            }
            .padding(DesignTokens.Spacing.compact)
        }
    }

    /// 失败状态。
    ///
    /// 存在的理由和 `storageError` 横幅一样：素材读取失败的表现是
    /// 「面板一直空着」，和「确实没有素材」长得一模一样。必须能区分。
    private func failure(_ message: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.compact) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: DesignTokens.Icon.inline))
                .foregroundStyle(DesignTokens.Surface.warning)
            Text(message)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Surface.secondaryText)
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await source.provider.refresh() }
            }
            .controlSize(.small)
        }
        .padding(DesignTokens.Spacing.loose)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 调宽

    /// 右边缘的拖拽调宽把手。
    ///
    /// 命中区域比可见的 1pt 分隔线宽得多——只给 1pt 的话实际根本拖不中。
    /// 这正是 Pin Web P0.3.1 里那个「把手拖不动」的 bug 的成因，
    /// 原生版不重蹈覆辙。
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(.rect)
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .accessibilityLabel("调整素材面板宽度")
            .accessibilityValue("\(Int(width)) 点")
            .gesture(
                // ## 必须是 `.global`，这是"把手跟不上鼠标"的根因
                //
                // 默认的 `.local` 量的是**把手自己那个坐标系**里的位移。
                // 而把手贴在面板右边缘——面板的宽度正是被这次拖拽改的，
                // 也就是说**把手一边被拖一边跟着跑**。鼠标右移 10pt、把手也
                // 右移 10pt，在把手自己的坐标系里鼠标等于没动过，位移自我抵消。
                // 表现就是边框永远比鼠标慢半拍，鼠标都出窗口了宽度还没跟上。
                //
                // `.global` 量的是窗口坐标，与把手自己怎么动无关。
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? width
                        if dragStartWidth == nil { dragStartWidth = start }
                        // 上界用 `max(...)` 兜一道：窗口被拉得极窄时算出来的
                        // 可用宽度可能比最小宽度还小，而 `200...180` 这样的
                        // 区间是**崩**，不是钳制。
                        let upper = max(DesignTokens.Metrics.panelMinWidth, maxWidth)
                        width = (start + value.translation.width).clamped(
                            to: DesignTokens.Metrics.panelMinWidth...upper
                        )
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}
