import SwiftUI
import WebKit

/// 把模型持有的那张网页挂进 SwiftUI 视图树。
///
/// ## 这个类型故意什么都不做
///
/// 它不创建 `WKWebView`（模型创建并持有）、不当 delegate（模型自己当）、
/// 不翻译任何事件。折叠面板时 SwiftUI 会拆掉这个视图，而网页仍然活在模型里
/// ——这正是"展开不用重新加载"的实现方式。这里多写一行状态，那条保证就多
/// 一个被破坏的机会。
struct WebBrowserHost: NSViewRepresentable {
    let model: WebBrowserModel

    func makeNSView(context _: Context) -> WKWebView {
        // 上一次挂载被拆掉时 AppKit 已经把它摘下来了；仍然显式摘一次，
        // 免得"回到已有父视图的视图"这种未定义情况。
        model.webView.removeFromSuperview()
        return model.webView
    }

    func updateNSView(_: WKWebView, context _: Context) {}

    /// 视图树被拆掉时不销毁网页——它归模型所有。这里只把它从父视图上摘下来，
    /// 免得一个已经不在树里的视图还挂着 AppKit 的布局关系。
    static func dismantleNSView(_ nsView: WKWebView, coordinator _: ()) {
        nsView.removeFromSuperview()
    }
}
