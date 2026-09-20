import Observation
import WebKit

/// 内嵌浏览器（花瓣来源的内容面）。
///
/// ## 网页由**模型**持有，不是由视图持有
///
/// 这条是硬要求，不是风格选择：花瓣要登录才看得全，而登录态虽然存在 WebKit
/// 自己的容器里，**页面本身不是**——视图持有 `WKWebView` 的话，折叠面板或切走
/// 来源时 SwiftUI 会拆掉视图、网页被销毁，再展开就是一次重新加载。
/// 用户的感受是"我刚登录完，怎么又要加载"。
///
/// 所以 `WKWebView` 在这里创建并强引用，`WebBrowserHost` 只是把同一个实例
/// 挂进视图树、再挂出去。视图拆了，网页还在。
///
/// ## 登录态为什么不归我们管
///
/// 用 `WKWebsiteDataStore.default()`：Cookie、localStorage 都由 WebKit 自己
/// 按容器落盘。这里**不读、不导出、不落库**任何账号信息——Pin 的素材库和日志
/// 里都不会出现花瓣的凭据。
///
/// ## 导航状态为什么不用 KVO
///
/// `canGoBack` / `canGoForward` / `isLoading` / `url` 都是 KVO 属性，但观察闭包
/// 是 `@Sendable` 的，读不到主 actor 上的 `WKWebView`；绕过去只能用
/// `assumeIsolated`，而它在不在主线程时会**直接崩**。为了一条前进/后退按钮的
/// 可控状态押上崩溃风险不划算——这些值在每次导航回调里都读得到。
@MainActor
@Observable
final class WebBrowserModel: NSObject {

    /// 来源面板打开时的起始页。
    static let home = URL(string: "https://huaban.com/")!
    static let pinterest = URL(string: "https://www.pinterest.com/")!

    /// 地址栏的文本。用户键入时改它，回车才导航；网页自己跳转时由模型改写。
    var address: String

    /// 当前页面地址。`nil` 表示还没开始加载。
    private(set) var pageURL: URL?
    private(set) var pageTitle = ""
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    /// 加载失败的原因。**非空就要显示出来**：失败的表现是"白板一块"，
    /// 和"页面还在加载"长得一模一样。
    private(set) var failure: String?

    /// 地址栏是否正在被编辑。由面板在聚焦时置位。
    var isEditingAddress = false

    /// 真正干活的网页。见类型说明里为什么由模型持有。
    let webView: WKWebView

    private var didLoadHome = false

    override init() {
        let configuration = WKWebViewConfiguration()
        // 默认容器 = 登录态跨启动保留（Spike 已实测）。换 profile 不会换容器，
        // 这是当前明确接受的取舍。
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        address = Self.home.absoluteString
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    /// 首次真正用到时才加载。放在 `init` 里的话，**根本没打开过花瓣来源的启动**
    /// 也会先发一趟网络请求。
    func loadHomeIfNeeded() {
        guard !didLoadHome, webView.url == nil else { return }
        didLoadHome = true
        webView.load(URLRequest(url: Self.home))
    }

    // MARK: - 地址栏

    /// 地址栏回车。只接受 http / https——`file://` 和 `javascript:` 在这条入口上
    /// 没有任何正当用途，放进来只会变成一个说不清的问题。
    func openTypedAddress() {
        guard let url = Self.normalized(address) else {
            failure = "只支持 http 或 https 地址"
            return
        }
        failure = nil
        webView.load(URLRequest(url: url))
    }

    func open(_ url: URL) {
        failure = nil
        address = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    /// 补全 scheme：用户习惯直接敲 `huaban.com`。
    static func normalized(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    // MARK: - 导航

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }

    /// 从网页读回当前状态。每次导航回调都调一次。
    ///
    /// - Parameter loading: 已知的加载状态。`nil` = 不改，只同步地址与前进后退。
    private func sync(loading: Bool? = nil) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let loading { isLoading = loading }
        pageURL = webView.url
        pageTitle = webView.title ?? ""
        // 用户正在地址栏里打字时不覆盖——否则输入到一半被跳转改掉。
        if !isEditingAddress, let url = webView.url { address = url.absoluteString }
    }
}

// MARK: - 导航回调

extension WebBrowserModel: WKNavigationDelegate {

    func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation?) {
        failure = nil
        sync(loading: true)
    }

    /// 内容开始到达。**地址与前进后退在这里就变了**：等到 `didFinish` 才更新的话，
    /// 慢页面上地址栏会长时间停在上一页，用户以为链接点错了。
    func webView(_: WKWebView, didCommit _: WKNavigation?) {
        sync()
    }

    func webView(_: WKWebView, didFinish _: WKNavigation?) {
        failure = nil
        sync(loading: false)
    }

    func webView(_: WKWebView, didFail _: WKNavigation?, withError error: any Error) {
        failure = Self.describe(error)
        sync(loading: false)
    }

    func webView(
        _: WKWebView, didFailProvisionalNavigation _: WKNavigation?, withError error: any Error
    ) {
        failure = Self.describe(error)
        sync(loading: false)
    }

    /// 取消的导航不是失败。网页自己取消一次跳转（换页、重定向）报出来的
    /// `NSURLErrorCancelled` 如果当成失败显示，用户会看到一闪而过的红字。
    private static func describe(_ error: any Error) -> String? {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return nil }
        return "页面打不开：\(nsError.localizedDescription)"
    }
}

// MARK: - 新窗口

extension WebBrowserModel: WKUIDelegate {

    /// `target="_blank"` 落回当前这一张网页。
    ///
    /// 面板里只有一块画布放网页，开不了新窗口；不接的话这类链接点了**毫无反应**
    /// ——花瓣的图片详情不少是这么开的。
    func webView(
        _ webView: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        webView.load(navigationAction.request)
        return nil
    }
}
