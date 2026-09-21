import AppKit
import CoreGraphics
import Foundation

/// SVG 的小型适配层。
///
/// 素材库仍只认识「可绘制的图片」，而 SVG 有两种完全不同的需求：入库时要保留
/// 原始 XML，绘制时又需要一张 `CGImage`。把 AppKit 的 SVG 解码放在这里，避免
/// 让导入、剪贴板和渲染路径各自猜一次格式、各自转一次 PNG。
enum SVGImageSupport {

    /// SVG 没有可靠的 ImageIO 文件头；扩展名是文件导入的快速路径，字节嗅探则
    /// 覆盖浏览器放进剪贴板的 `public.svg-image` 数据。
    static func isSVG(url: URL) -> Bool {
        guard url.pathExtension.caseInsensitiveCompare("svg") == .orderedSame,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        else { return false }
        return isSVG(data: data)
    }

    static func isSVG(data: Data) -> Bool {
        // SVG 的声明、注释和空白都可能在根节点之前；只看开头 64 KB 足够确认
        // 文档类型，也避免把一个异常大的文件完整解成 String。
        let prefix = data.prefix(64 * 1024)
        guard let text = String(data: prefix, encoding: .utf8) else { return false }
        return text.range(of: "<svg", options: [.caseInsensitive]) != nil
    }

    static func facts(at url: URL) -> ImageFileFacts? {
        guard isSVG(url: url),
              let image = NSImage(contentsOf: url),
              image.size.width > 0, image.size.height > 0
        else { return nil }
        return ImageFileFacts(pixelSize: image.size, exifOrientation: 1)
    }

    /// 在请求的最长边内绘制 SVG。这里不把结果写回磁盘：素材原件始终是 SVG，
    /// 缓存中的位图只是当前 LOD 的显示副本。
    static func rasterize(at url: URL, maxPixelSize: CGFloat) -> CGImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return rasterize(image, maxPixelSize: maxPixelSize)
    }

    private static func rasterize(_ image: NSImage, maxPixelSize: CGFloat) -> CGImage? {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let scale = min(1, maxPixelSize / max(sourceSize.width, sourceSize.height))
        let width = max(1, Int((sourceSize.width * scale).rounded()))
        let height = max(1, Int((sourceSize.height * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }
}
