import CoreGraphics
import Foundation

/// 批次 B 的图片提供者：像素是**程序合成**的，不读磁盘。
///
/// ## 为什么不用真实素材
///
/// 路线图 §6 要求原生版从全新空库开始，测试只用合成或专用测试素材。合成还有一个
/// 真实素材给不了的好处：**尺寸、数量、内容全部可控**，所以「1000 个元素」
/// 「全是 4K」「解码失败」这些场景才做得出来——用真实素材只能碰运气凑。
///
/// ## 素材长什么样，以及为什么这么画
///
/// 每张图三层，每层各有用处：
///
/// 1. **底色**（色相由素材 ID 决定）——一眼看出"这是哪张图"。同一素材每次都是
///    同一个颜色，所以重解码不会让人以为是换了张图。
/// 2. **两个大色块**，尺寸按图片**比例**给——任何档位上看起来都一样。
///    这一层是**稳定的参照**：换档时如果连它都变了，说明尺寸算错了，
///    而不是"变糊了"。
/// 3. **分辨率楔形**（一组线宽渐变的细线）——**它是真的会被降采样吃掉的**。
///    这才是"糊"的诚实呈现（照片里的细纹理同理），也是 B2 肉眼判断
///    "当前这一帧到底是哪个档位"的依据。用刻意保持清晰的图案当素材，
///    会让 LOD 的效果永远看不出来。
@MainActor
final class SyntheticImageProvider: ImageProvider {

    /// 一张合成素材的规格。
    struct Asset: Sendable {
        let id: AssetID
        /// 原图像素尺寸。
        let pixelSize: CGSize
    }

    /// 素材表。ID → 原图像素尺寸。
    private let assets: [AssetID: CGSize]

    /// 共享缓存。**由外部注入**，不是内部 new 出来的——批次 C 的素材面板要拿到
    /// 同一个实例，否则面板缩略图和画布元素会各解码一份（见 `ImageCache` 的说明）。
    let cache: ImageCache

    // MARK: - 自检可见的状态

    /// 真正发生过多少次解码（不含缓存命中）。
    ///
    /// 「切画布不重解码」这条断言读的就是它：切过去再切回来，计数必须不变。
    /// 只看缓存大小是证不出来的——那只能说明有东西在里面，不能说明这次没解码。
    private(set) var decodeCount = 0

    /// **在解码开始之前**就被取消掉的请求数（B2）。
    ///
    /// 它是"取消真的省下了东西"的计数：这个数每涨一次，就少解一张图。
    /// `decodeCount` 是证不出这件事的——取消省下的是**没发生**的解码，
    /// 而没发生的事情在计数上留不下痕迹。
    private(set) var cancelledBeforeDecodeCount = 0

    /// 最近一次解码是否**不在主线程**上跑。
    ///
    /// 这是「主线程零解码」的探针。`nonisolated async` 函数应当跑在全局执行器上，
    /// 而不是调用方的主 actor——但这条依赖编译器的执行语义（SE-0338），
    /// 不是读代码能确认的。所以用断言钉住：哪天它退回主线程，断言先红。
    private(set) var lastDecodeWasOffMainThread: Bool?

    /// 同一素材同一档位的并发请求合并。键在第一次 await 之前写入，避免
    /// 两个调用点同时穿透到解码。
    private var inFlight: [ImageCache.Key: Task<GenerationOutcome, Never>] = [:]

    init(assets: [Asset], cache: ImageCache = ImageCache()) {
        self.assets = Dictionary(
            assets.map { ($0.id, $0.pixelSize) },
            uniquingKeysWith: { first, _ in first }
        )
        self.cache = cache
    }

    // MARK: - ImageProvider

    func metadata(for asset: AssetID) async -> ImageMetadata? {
        guard let pixelSize = assets[asset] else { return nil }
        return ImageMetadata(pixelSize: pixelSize)
    }

    func image(for asset: AssetID, targetPixelSize: CGSize) async -> ImageRequestResult {
        guard let original = assets[asset] else { return .missing }

        let tier = LODTier.fitting(targetPixelSize, original: original)
        let size = tier.pixelSize(forOriginal: original)
        if let cached = cache.image(for: asset, tier: tier) {
            return .image(cached)
        }

        // 取消的判据放在**解码开始之前**（B2）。
        //
        // 这是取消唯一能真正省下东西的位置：一旦进了 `render(...)`，那是一串
        // C 层的 `CGContext` 调用，外面没法打断它。而"还没开始"恰恰是最常见的
        // 情况——连续缩放会排出一串请求，前面几个在轮到自己之前就被后一个顶掉了。
        if Task.isCancelled {
            cancelledBeforeDecodeCount += 1
            return .cancelled
        }

        let key = ImageCache.Key(asset: asset, tier: tier)
        let outcome: GenerationOutcome
        if let existing = inFlight[key] {
            outcome = await existing.value
        } else {
            let seed = Self.seed(from: asset)
            let task = Task { await Self.generate(seed: seed, pixelSize: size) }
            inFlight[key] = task
            outcome = await task.value
            // 从 await 回到主 actor 之后到这里没有再次挂起，中间不存在"任务已清、
            // 缓存未写"的窗口，所以第三个调用点一定命中缓存而不是重复解码。
            inFlight[key] = nil
            lastDecodeWasOffMainThread = outcome.ranOffMainThread
            decodeCount += 1
        }

        guard let image = outcome.image else {
            return .failed("合成失败：\(Int(size.width))×\(Int(size.height))")
        }
        // 解码**已经跑完**的请求即使被取消，结果也照常入缓存：这份工作已经付过
        // 代价了，丢掉它只会让下次再付一遍。取消要挡的是"还没开始的解码"，
        // 不是"已经花掉的算力"。
        cache.store(image, for: asset, tier: tier)
        return .image(image)
    }

    // MARK: - 合成

    private struct GenerationOutcome: Sendable {
        let image: CGImage?
        let ranOffMainThread: Bool
    }

    /// 非隔离的 `async`：由全局执行器执行，**不占用调用方的主 actor**。
    ///
    /// 下面那句就是探针本身，不是日志。真实现（ImageIO）同样要落在这个位置，
    /// 否则路线图 §2.4 的「主线程 P95 < 8ms」守不住。
    ///
    /// 用的是 `pthread_main_np()` 而不是 `Thread.isMainThread`：Foundation 把后者
    /// 在异步上下文里标成了 unavailable——编译器认为"异步上下文里问是不是主线程"
    /// 本身就是可疑的。这个判断对我们的用途不成立（我们要问的恰恰是"有没有意外
    /// 留在主线程上"），所以退到 C 层问。主 actor 跑在主线程上，两者在这里等价。
    private nonisolated static func generate(seed: UInt64, pixelSize: CGSize) async -> GenerationOutcome {
        let onMainThread = pthread_main_np() != 0
        return GenerationOutcome(
            image: render(seed: seed, pixelSize: pixelSize),
            ranOffMainThread: !onMainThread
        )
    }

    private nonisolated static func render(seed: UInt64, pixelSize: CGSize) -> CGImage? {
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        let hue = Double(seed % 360) / 360
        let value = 0.62 + Double((seed >> 8) % 24) / 100

        // 第一层：底色。
        context.setFillColor(color(hue: hue, saturation: 0.34, value: value))
        context.fill(CGRect(origin: .zero, size: size))

        // 第二层：两个大色块，按图片比例给尺寸——换档时它不该有任何变化。
        context.setFillColor(color(hue: hue, saturation: 0.48, value: value * 0.78))
        context.fill(CGRect(x: size.width * 0.07, y: size.height * 0.55,
                            width: size.width * 0.36, height: size.height * 0.38))
        context.setFillColor(color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1),
                                   saturation: 0.55, value: min(1, value * 1.25)))
        context.fill(CGRect(x: size.width * 0.53, y: size.height * 0.09,
                            width: size.width * 0.40, height: size.height * 0.60))

        // 第三层：分辨率楔形。线宽 1px，间距分三组递增——降采样时最细的一组先
        // 并成灰面，再是中间那组。所以"当前是哪个档位"是**看得见**的。
        context.setFillColor(color(hue: hue, saturation: 0.10, value: 0.98))
        let bandTop = size.height * 0.86
        let bandHeight = size.height * 0.10
        var x = size.width * 0.06
        let rightEdge = size.width * 0.94
        for (index, spacing) in [2, 4, 8].enumerated() {
            let groupEnd = size.width * (0.06 + 0.29 * Double(index + 1))
            while x < min(groupEnd, rightEdge) {
                context.fill(CGRect(x: x, y: bandTop, width: 1, height: bandHeight))
                x += CGFloat(spacing)
            }
            x = groupEnd + size.width * 0.02
        }

        return context.makeImage()
    }

    /// 素材 ID → 稳定的 64 位种子（FNV-1a）。
    ///
    /// 必须是纯函数：同一素材每次合成都得到同一张图。用随机数的话，重解码会让
    /// 画面变一个颜色，"缓存没命中"就伪装成了"内容变了"。
    private nonisolated static func seed(from asset: AssetID) -> UInt64 {
        withUnsafeBytes(of: asset.raw.uuid) { bytes in
            bytes.reduce(into: UInt64(0xcbf2_9ce4_8422_2325)) { hash, byte in
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            }
        }
    }

    /// 色调到这里为止只出现一次：合成图与真实图的颜色来源不同，但"给一个色相
    /// 拿到一个 CGColor"不该各写一份。
    private nonisolated static func color(hue: Double, saturation: Double, value: Double) -> CGColor {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let sector = Int(h)
        let f = h - Double(sector)
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * f)
        let t = value * (1 - saturation * (1 - f))
        let (r, g, b): (Double, Double, Double)
        switch sector % 6 {
        case 0: (r, g, b) = (value, t, p)
        case 1: (r, g, b) = (q, value, p)
        case 2: (r, g, b) = (p, value, t)
        case 3: (r, g, b) = (p, q, value)
        case 4: (r, g, b) = (t, p, value)
        default: (r, g, b) = (value, p, q)
        }
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

// MARK: - 合成素材目录

extension SyntheticImageProvider {

    /// 建一批合成素材。
    ///
    /// ## 尺寸分布为什么是混合的
    ///
    /// 全部用 4K 会得到一条"很吓人但没意义"的曲线：真实的设计工作里，画布上
    /// 同时有 4K 摄影稿、Retina 截图和手机竖图。全 4K 的场景 B2 会单独跑一档
    /// 作为压力上限，但**默认场景必须是混合的**，否则测出来的数字不能代表日常。
    ///
    /// 三种尺寸都取自真实存在的规格，不是编的：
    ///
    /// - `3840×2160` — 4K 摄影稿
    /// - `3456×2234` — 内建 Liquid Retina XDR 的整屏截图
    /// - `1170×2532` — iPhone 竖屏截图
    static func makeAssets(count: Int) -> [Asset] {
        let sizes = [
            CGSize(width: 3840, height: 2160),
            CGSize(width: 3456, height: 2234),
            CGSize(width: 1170, height: 2532),
        ]
        return (0..<max(0, count)).map { index in
            Asset(id: AssetID(), pixelSize: sizes[index % sizes.count])
        }
    }

    /// 全部 4K 的压力档，供 B2 的性能上限测试使用。
    static func makeUniform4KAssets(count: Int) -> [Asset] {
        (0..<max(0, count)).map { _ in
            Asset(id: AssetID(), pixelSize: CGSize(width: 3840, height: 2160))
        }
    }
}
