import AppKit
import WebKit

/// `--self-check` 的无头冒烟检查：只回答“WebKit 能不能加载这个页面”和
/// “剪贴板链路通不通”，不做任何图片提取，不触碰网站 DOM 里的图片。
@MainActor
enum SelfCheck {
    /// 自检不留运行痕迹：清掉它自己生成的夹具目录。
    nonisolated static func cleanup() {
        LocalFixturePage.cleanupSharedDirectory()
    }

    static func run(online: Bool) async -> Int32 {
        var failures = 0

        print("== WebCaptureSpike 自检 ==")

        let fixture = LocalFixturePage()
        if await load(fixture.indexURL, readingDirectory: fixture.directory, label: "本地对照页") {
            print("PASS  本地对照页加载")
        } else {
            print("FAIL  本地对照页加载")
            failures += 1
        }

        if await clipboardRoundTrip() {
            print("PASS  剪贴板图片字节解码")
        } else {
            print("FAIL  剪贴板图片字节解码")
            failures += 1
        }

        if online {
            if await load(URL(string: "https://huaban.com/")!, readingDirectory: nil, label: "花瓣") {
                print("PASS  花瓣首页加载")
            } else {
                print("FAIL  花瓣首页加载")
                failures += 1
            }
        } else {
            print("SKIP  真实网站加载（未传 --online）")
        }

        print("== 失败项：\(failures) ==")
        return failures == 0 ? 0 : 1
    }

    /// 造一张 PNG 放进一个私有 pasteboard，再走正式接收路径解出来。
    /// 用私有 pasteboard 是为了不覆盖用户当前剪贴板。
    private static func clipboardRoundTrip() async -> Bool {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("WebCaptureSpikeSelfCheck"))
        pasteboard.clearContents()
        let png = LocalFixturePage.syntheticImage(type: .png, transparent: false, width: 64)
        pasteboard.setData(png, forType: .png)

        let receiver = CaptureReceiver()
        let snapshot = receiver.snapshot(of: pasteboard)
        guard case .success(let payload) = receiver.payload(from: snapshot) else { return false }
        guard case .success(let success) = await receiver.receive(
            payload, transport: .clipboardBytes, pasteboardTypes: snapshot.types
        ) else { return false }
        print("      像素 \(Int(success.pixelSize.width))×\(Int(success.pixelSize.height))，"
            + "\(success.byteCount) 字节，类型 \(success.mediaType ?? "未知")")
        return success.pixelSize == CGSize(width: 64, height: 44)
    }

    private static func load(
        _ url: URL, readingDirectory directory: URL?, label: String
    ) async -> Bool {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 1_024, height: 768), configuration: configuration)

        let result = LoadProbe()
        webView.navigationDelegate = result

        if let directory {
            webView.loadFileURL(url, allowingReadAccessTo: directory)
        } else {
            webView.load(URLRequest(url: url))
        }
        await result.wait()
        print("      \(label)：\(result.summary) 最终地址 \(result.finalURL ?? url.absoluteString)")
        return result.succeeded
    }
}

@MainActor
private final class LoadProbe: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var succeeded = false
    private(set) var summary = "未开始"
    private(set) var finalURL: String?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    private func finish(_ succeeded: Bool, _ summary: String, _ url: String?) {
        guard continuation != nil else { return }
        self.succeeded = succeeded
        self.summary = summary
        self.finalURL = url
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation?) {
        finish(true, "加载完成，标题「\(webView.title ?? "")」", webView.url?.absoluteString)
    }

    func webView(_: WKWebView, didFail _: WKNavigation?, withError error: Error) {
        finish(false, "加载失败：\(error.localizedDescription)", nil)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation?, withError error: Error) {
        finish(false, "导航失败：\(error.localizedDescription)", nil)
    }
}
