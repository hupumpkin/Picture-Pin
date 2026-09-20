import SwiftUI
import WebKit

@MainActor
final class WebViewController: ObservableObject {
    @Published var pageURL: URL?
    @Published var title = "未加载"
    @Published var isLoading = false
    private weak var webView: WKWebView?

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func load(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }

    func loadFixture(_ url: URL, allowingReadAccessTo directory: URL) {
        webView?.loadFileURL(url, allowingReadAccessTo: directory)
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    var canGoBack: Bool { webView?.canGoBack ?? false }
    var canGoForward: Bool { webView?.canGoForward ?? false }
}

struct WebViewHost: NSViewRepresentable {
    @ObservedObject var controller: WebViewController
    let initialURL: URL

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The default store deliberately preserves user-managed login state between
        // runs, while this Spike never reads or exports those cookies.
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        controller.attach(view)
        controller.load(initialURL)
        return view
    }

    func updateNSView(_: WKWebView, context _: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private weak var controller: WebViewController?

        init(controller: WebViewController) { self.controller = controller }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation?) {
            controller?.isLoading = true
            controller?.pageURL = webView.url
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation?) {
            controller?.isLoading = false
            controller?.pageURL = webView.url
            controller?.title = webView.title ?? webView.url?.host ?? "已加载"
        }

        func webView(_: WKWebView, didFail _: WKNavigation?, withError error: Error) {
            controller?.isLoading = false
            controller?.title = "加载失败：\(error.localizedDescription)"
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith _: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures _: WKWindowFeatures
        ) -> WKWebView? {
            // Keep target=_blank navigation in this one Spike window.
            if navigationAction.targetFrame == nil, let request = navigationAction.request as URLRequest? {
                webView.load(request)
            }
            return nil
        }
    }
}
