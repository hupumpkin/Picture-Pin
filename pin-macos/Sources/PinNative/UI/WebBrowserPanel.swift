import SwiftUI

/// 「花瓣」来源的内容面：一个能在侧边面板里真的浏览网站的网页。
///
/// ## 它和列表形态的区别只在内容
///
/// 面板的外壳（标题、玻璃卡、调宽把手）全部由 `MaterialPanel` 负责，这里只管
/// 面板**里面**那一块。所以这个视图不知道自己在侧边栏、也不知道面板有多宽。
///
/// 采集（复制/拖拽进画布）不在这一层做：那三条通道统一走 `ImportCoordinator`，
/// 接进来的时候也接在那个入口上，这里不另开一条。
struct WebBrowserPanel: View {
    @Bindable var model: WebBrowserModel
    let onPasteFromClipboard: () -> Void
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider().overlay(DesignTokens.Surface.separator)
            page
            Divider().overlay(DesignTokens.Surface.separator)
            importButton
        }
        // 第一次真正显示时才加载。放在 init 里的话，只开过截图来源的启动
        // 也会先替用户访问一趟花瓣。
        .task { model.loadHomeIfNeeded() }
    }

    // MARK: - 导航条

    private var navigationBar: some View {
        HStack(spacing: DesignTokens.Spacing.tight) {
            ToolbarIconButton(
                systemImage: "chevron.left", help: "后退",
                isEnabled: model.canGoBack
            ) { model.goBack() }

            ToolbarIconButton(
                systemImage: "chevron.right", help: "前进",
                isEnabled: model.canGoForward
            ) { model.goForward() }

            ToolbarIconButton(
                systemImage: model.isLoading ? "xmark" : "arrow.clockwise",
                help: model.isLoading ? "停止加载" : "刷新"
            ) {
                if model.isLoading { model.stopLoading() } else { model.reload() }
            }

            Menu {
                Button("花瓣") { model.open(WebBrowserModel.home) }
                Button("Pinterest") { model.open(WebBrowserModel.pinterest) }
            } label: {
                Image(systemName: "bookmark")
            }
            .menuStyle(.borderlessButton)
            .help("网站快捷入口")
            .accessibilityLabel("网站快捷入口")

            addressField
        }
        .padding(.horizontal, DesignTokens.Spacing.compact)
        .frame(height: DesignTokens.Metrics.browserToolbarHeight)
    }

    private var importButton: some View {
        Button(action: onPasteFromClipboard) {
            Label("将剪贴板图片放入画布", systemImage: "arrow.down.doc")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .padding(DesignTokens.Spacing.compact)
        .accessibilityLabel("将剪贴板图片放入画布")
    }

    /// 地址栏。**回车才导航**，键入过程中不跳转——边打边跳的话，
    /// 输到一半的地址会被当成真地址去访问。
    private var addressField: some View {
        TextField("网址", text: $model.address)
            .textFieldStyle(.plain)
            .font(DesignTokens.Typography.caption)
            .lineLimit(1)
            .focused($isAddressFocused)
            .onSubmit { model.openTypedAddress() }
            .onChange(of: isAddressFocused) { _, focused in
                // 聚焦期间网页跳转不改写地址栏，否则输入会被半路冲掉。
                model.isEditingAddress = focused
            }
            .padding(.horizontal, DesignTokens.Spacing.compact)
            .padding(.vertical, DesignTokens.Spacing.tight)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                    .fill(DesignTokens.Surface.panel)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                    .strokeBorder(DesignTokens.Surface.floatingPanelBorder, lineWidth: 1)
            }
            .accessibilityLabel("网址")
    }

    // MARK: - 网页

    private var page: some View {
        WebBrowserHost(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { loadingBar }
            .overlay(alignment: .top) { failureBanner }
    }

    /// 加载进度条。**细到几乎只是一条线**：它要说的是"还在动"，不是"有事发生"。
    @ViewBuilder private var loadingBar: some View {
        if model.isLoading {
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
                .labelsHidden()
                .transition(.opacity)
        }
    }

    /// 加载失败。网页失败的表现是**一整块白**，和"还没加载完"分不开——
    /// 所以这条必须压在最上面，而不是等用户去猜。
    @ViewBuilder private var failureBanner: some View {
        if let failure = model.failure {
            Text(failure)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Surface.secondaryText)
                .multilineTextAlignment(.center)
                .padding(DesignTokens.Spacing.regular)
                .frame(maxWidth: .infinity)
                .background(.thinMaterial)
                .accessibilityElement(children: .combine)
        }
    }
}
