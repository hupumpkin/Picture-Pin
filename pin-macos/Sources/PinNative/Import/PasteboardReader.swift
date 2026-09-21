import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 真剪贴板的读者。**全项目唯一 import AppKit 的采集代码**——采集的其余部分
/// 都只认 `ClipboardPayload`，所以"剪贴板里到底有什么"这条平台知识只有这一份。
///
/// ## 读的顺序：先文件，后位图
///
/// 在访达里复制一张图，剪贴板里**两样都有**（文件 URL + 该文件的位图预览）。
/// 先读文件 URL 是刻意的：原图还在磁盘上，直接复制过来，格式、分辨率、
/// 元数据原样保留；走位图那条路等于把图片重新编码一遍再存，白白掉一代画质。
///
/// ## 只读，绝不写
///
/// 这里没有任何一处 `declareTypes` / `setData`。改剪贴板的表现是用户复制了
/// 一张图、粘出来却是别的东西——而且他不会怀疑是我们干的。
struct PasteboardReader: ClipboardReading {

    /// 位图读取器与画布拖拽注册共用这份清单，避免界面宣称能接收、读取器却
    /// 生成不了载荷。
    static let bitmapTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("org.webmproject.webp"),
        NSPasteboard.PasteboardType("com.compuserve.gif"),
    ]

    /// 浏览器和设计工具复制矢量图时的标准粘贴板类型。
    static let svgType = NSPasteboard.PasteboardType("public.svg-image")
    /// Chromium 等应用会把「复制 SVG」写成纯文本，不声明 `public.svg-image`。
    /// 只在文本本身通过 SVG 根节点验证时才接受，普通文字绝不会被当素材导入。
    static let svgTextTypes: [NSPasteboard.PasteboardType] = [.string]

    static let acceptedDragTypes: Set<NSPasteboard.PasteboardType> =
        Set(bitmapTypes + [svgType, .fileURL])

    /// 读哪块剪贴板。默认是系统剪贴板；自检传一块私有的（见 `ClipboardReading`）。
    let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func read() -> ClipboardPayload {
        // 一、文件 URL。`readObjects` 只返回**真实存在**的 URL：
        // 从某些 App 复制出来的文件引用在文件被删掉之后仍留在剪贴板上，
        // 那种 URL 交下去只会在导入时报一个用户看不懂的错。
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let files = urls.filter { $0.isFileURL && !isDirectory($0) }
            if !files.isEmpty { return .fileURLs(files) }
        }

        // SVG 必须排在 TIFF 等预览位图之前：浏览器通常同时放两份数据，选预览
        // 就会把可编辑的矢量原件悄悄降级成位图。
        if let data = pasteboard.data(forType: Self.svgType), SVGImageSupport.isSVG(data: data) {
            return .svg(data: data, suggestedName: Self.suggestedSVGName())
        }
        for type in Self.svgTextTypes {
            if let data = pasteboard.data(forType: type), SVGImageSupport.isSVG(data: data) {
                return .svg(data: data, suggestedName: Self.suggestedSVGName())
            }
        }

        // 二、位图。PNG 优先（无损、且已经是我们要落盘的格式，不必转码）；
        // TIFF 是剪贴板位图的通用形态（截图工具、多数浏览器都给这个）。
        for type in Self.bitmapTypes {
            if let data = pasteboard.data(forType: type),
               let payload = makeImagePayload(from: data, alreadyPNG: type == .png) {
                return payload
            }
        }

        // 三、剩下的都算"没有图片"。复制了一段文字、复制了一个 PDF 文件引用
        // 之外的东西，都在这一支——用户看到的文案是同一条（见 `.none` 的注释）。
        return .none
    }

    /// 把剪贴板位图整成一份可以落盘的数据。
    ///
    /// 需要它是 PNG 的原因和读的顺序是同一件事：`AssetStore.ingest` 按扩展名
    /// 落盘，位图没有文件名，我们给它 `.png`，那字节就必须真的是 PNG。
    private func makeImagePayload(from data: Data, alreadyPNG: Bool) -> ClipboardPayload? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // 尺寸在**入库之前**就要有：素材面板与网格排布都按原比例算，
        // 入库之后才知道的话第一帧会按错误的尺寸摆一次。
        guard let pixelSize = pixelSize(of: source), pixelSize.width >= 1, pixelSize.height >= 1 else {
            return nil
        }
        let png = alreadyPNG ? data : reencodeAsPNG(source)
        guard let png, !png.isEmpty else { return nil }
        return .image(data: png, suggestedName: Self.suggestedName(), pixelSize: pixelSize)
    }

    private func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        // EXIF 方向 5–8 是"躺在一边"的四个值，宽高要换过来。剪贴板位图一般
        // 不带方向，但截图工具从一张带方向的照片里"复制图片"时会给过来——
        // 不换的话，那张图会以错误的长宽比排进网格（图本身是对的，格子是歪的）。
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    /// TIFF → PNG。走 `CGImageDestinationAddImageFromSource` 而不是先解成
    /// `NSBitmapImageRep`：前者允许 ImageIO 在格式之间直接搬，不必在进程里
    /// 摊开一整张位图——一张 8K 截图摊开就是 130 MB。
    private func reencodeAsPNG(_ source: CGImageSource) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// 位图没有文件名，给它起一个**一眼能认出是粘贴进来的**名字。
    ///
    /// 带时间戳不是为了好看：素材面板里连粘五张，五个条目得能区分开；
    /// 而"粘贴 1/2/3"这种序号在重启之后就对不上任何东西了。
    static func suggestedName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "粘贴 \(formatter.string(from: now)).png"
    }

    static func suggestedSVGName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "粘贴 \(formatter.string(from: now)).svg"
    }
}
