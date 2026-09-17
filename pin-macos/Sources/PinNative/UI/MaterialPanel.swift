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

    @State private var dragStartWidth: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DesignTokens.Surface.separator)
            content
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        // 浮在画布上的一张玻璃卡：圆角、描边、投影（见 `floatingPanelSurface`）。
        // 第一版是 `.background(实色)` 且贴着窗口左边——那读起来是"中间那一栏"，
        // 画布被它切成两半，而不是"画布上浮着一张卡"。
        .floatingPanelSurface()
        // 把手挂在裁剪**之后**：它的命中区比可见的 1pt 宽得多，有一半在面板外，
        // 先裁的话那半个命中区会被切掉，拖起来只有一半灵。
        .overlay(alignment: .trailing) { resizeHandle }
        // 切换来源时拉一次。重复调用是安全的——`refresh()` 约定为幂等。
        .task(id: source.id) {
            await source.provider.refresh()
        }
    }

    private var header: some View {
        HStack {
            Text(source.title)
                .font(DesignTokens.Typography.panelTitle)
            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.regular)
        .frame(height: 34)
    }

    // MARK: - 内容

    /// 按形态分派。新增形态时这里会编译不过，直到新形态被实现——
    /// 这是故意的：遗漏是编译错误，不是界面上一片空白。
    @ViewBuilder
    private var content: some View {
        switch source.surface {
        case .collection:
            collection
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

    /// 条目列表。
    ///
    /// **这是批次 C 的占位形态。** 真实的素材列表要接解码与 LOD 缓存
    /// （路线图 §2.3），缩略图尺寸、分组、排序都还没定。这里只做一件事：
    /// 让 `.loaded(非空)` 有真实渲染，而不是悄悄退回空状态——
    /// 那样会留下一个「有素材却显示"还没有截图"」的 bug。
    private func collectionList(_ items: [MaterialItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.Spacing.compact) {
                ForEach(items) { item in
                    HStack(spacing: DesignTokens.Spacing.compact) {
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                            .fill(DesignTokens.Surface.rail)
                            .frame(width: 28, height: 28)
                            .overlay {
                                Image(systemName: item.kind == .font ? "a.square" : "photo")
                                    .font(.system(size: DesignTokens.Icon.inline))
                                    .foregroundStyle(DesignTokens.Surface.secondaryText)
                            }
                        Text(item.title)
                            .font(DesignTokens.Typography.caption)
                            .lineLimit(1)
                        Spacer(minLength: 0)
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
                .foregroundStyle(.orange)
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
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartWidth ?? width
                        if dragStartWidth == nil { dragStartWidth = start }
                        width = (start + value.translation.width).clamped(
                            to: DesignTokens.Metrics.panelMinWidth...DesignTokens.Metrics.panelMaxWidth
                        )
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}
