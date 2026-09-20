import CoreGraphics
import Foundation
import ImageIO

/// 真实素材的图片提供者：像素来自磁盘上的图片文件，解码只走 ImageIO（§3.2）。
///
/// 与 `SyntheticImageProvider` 是同一份 `ImageProvider` 契约的两种实现，差别只有
/// 像素从哪来。这里立的是**真链路的规矩**，每一条都有对应断言：
///
/// - **缩略图路径解码**：`CGImageSourceCreateThumbnailAtIndex`，绝不
///   `CreateImageAtIndex` 整幅解码再缩。超长图（长图拼接、整页截图）整幅解码的
///   峰值内存会很难看——一张 20000×1000 的图整幅解出来是 76 MB，而画布上要的
///   可能只是 1/8。缩略图 API 在解码器内部降采样，峰值内存按目标尺寸走。
/// - **方向显式摆正**：`kCGImageSourceCreateThumbnailWithTransform` 开着，EXIF
///   方向在解码时消化掉——渲染器拿到的像素已经是摆正的，与
///   `ImageMetadata.pixelSize`（摆正之后）同一口径。这个开关是**实测钉住的**
///   （自检写真实 EXIF 方向 6 的 JPEG 走全链路），不是按记忆。
/// - **解码不在主线程**：与 `SyntheticImageProvider.generate` 同一个手法
///   （`nonisolated async` + `pthread_main_np()` 探针），§2.4 的主线程预算
///   靠它守住。
/// - **失败不抛错**：`.missing` / `.failed(统一文案)` / `.cancelled` 三个分支
///   齐活，调用方（渲染器）不用接 `try`。
///
/// ## 格式不做白名单
///
/// "能解码就收，判定只走 ImageIO"（§7 第 5 条）。文件能不能读、是什么格式，
/// 全由 ImageIO 回答：写白名单等于替 ImageIO 提前做了一半判断，而两处判断
/// 迟早会分叉（新格式在我们这边被拦下、旧格式在 ImageIO 那边突然读不了）。
/// 扩展名同样**只作参考**：`CGImageSource` 按内容嗅探格式，不按后缀。
@MainActor
final class FileImageProvider: ImageProvider, ImageFileProbing {

    /// 素材 → 磁盘位置。**注入**：唯一来源是 `SnapshotAssetLocator`（启动时装好），
    /// 解码路径上不允许出现数据库查询（见 `AssetFileLocator` 的说明）。
    let locator: any AssetFileLocator

    /// 共享缓存。**注入**，素材面板与画布要拿同一个实例——各建一个的话，
    /// 同一张图会各解码一遍，内存翻倍（`ImageCache` 的说明）。
    let cache: ImageCache

    /// 单次解码上限（§3.9 第 3 条）。归档时夹进 `LODTier.fitting`——注入点
    /// 留给自检：用小上限就能实测"超限图被夹到粗档"这条规则。
    private let decodePolicy: DecodePolicy

    // MARK: - 自检可见的状态

    /// 真正发生过多少次解码（不含缓存命中、不含 inFlight 合并）。
    private(set) var decodeCount = 0

    /// **在解码开始之前**就被取消掉的请求数（与合成实现同一个口径）。
    private(set) var cancelledBeforeDecodeCount = 0

    /// 最近一次解码是否**不在主线程**上跑（`pthread_main_np()` 探针）。
    private(set) var lastDecodeWasOffMainThread: Bool?

    /// 同一素材同一档位的并发请求合并。键在第一次 await 之前写入，
    /// 避免两个调用点同时穿透到解码（见 `SyntheticImageProvider` 同款注释）。
    private var inFlight: [ImageCache.Key: Task<DecodeOutcome, Never>] = [:]

    init(
        locator: any AssetFileLocator,
        cache: ImageCache = ImageCache(),
        decodePolicy: DecodePolicy = DecodePolicy()
    ) {
        self.locator = locator
        self.cache = cache
        self.decodePolicy = decodePolicy
    }

    // MARK: - ImageFileProbing

    /// 探一个还没入库的文件（导入时调用）。读不出来返回 `nil`。
    func probe(_ url: URL) async -> ImageFileFacts? {
        await Self.facts(at: url)
    }

    // MARK: - ImageProvider

    /// 账本就是缓存那一本，不另建（见 `ImageProvider.residency` 的说明）。
    var residency: ImageResidency { cache.residency }

    func metadata(for asset: AssetID) async -> ImageMetadata? {
        guard let url = locator.fileURL(for: asset) else { return nil }
        guard let facts = await Self.facts(at: url) else { return nil }
        return ImageMetadata(pixelSize: facts.pixelSize)
    }

    /// 同步探测缓存里有没有"不比给定档位更细"的一张。**不解码**（协议约定）。
    func cachedImage(for asset: AssetID, atMost tier: LODTier) -> CachedImage? {
        guard let found = cache.bestAvailableImage(for: asset, atMost: tier) else { return nil }
        return CachedImage(image: found.image, tier: found.tier)
    }

    func releaseOffscreenPixels(of asset: AssetID) {
        cache.demoteUnheldTiers(of: asset)
    }

    func image(for asset: AssetID, targetPixelSize: CGSize) async -> ImageRequestResult {
        guard let url = locator.fileURL(for: asset) else { return .missing }

        // 原图尺寸要先知道才能归档。这里读的是文件头，不解码像素。
        let probe = await Self.probeOutcome(at: url)
        let facts: ImageFileFacts
        switch probe {
        case .missing:
            return .missing
        case .undecodable:
            return .failed(Self.unifiedDecodeFailure)
        case .facts(let f):
            facts = f
        }

        // 调用方传的是"已经定下来的那一档"的尺寸（`LODTier.pixelSize(forOriginal:)`），
        // 这里再归一次档对它是恒等变换；对别的调用方则保证缓存键不随缩放漂移
        // （协议注释里的约定）。解码上限（§3.9 第 3 条）在这一步生效：
        // 归档结果永远不会比上限更细。
        let tier = LODTier.fitting(targetPixelSize, original: facts.pixelSize, policy: decodePolicy)
        let size = tier.pixelSize(forOriginal: facts.pixelSize)
        if let cached = cache.image(for: asset, tier: tier) {
            return .image(cached)
        }

        // 取消判据放在**解码开始之前**（B2）：一旦进了 ImageIO 的缩略图解码，
        // C 层没有中断点，外面打断不了。而"还没开始"恰恰是最常见的情况。
        if Task.isCancelled {
            cancelledBeforeDecodeCount += 1
            return .cancelled
        }

        let key = ImageCache.Key(asset: asset, tier: tier)
        let outcome: DecodeOutcome
        if let existing = inFlight[key] {
            outcome = await existing.value
        } else {
            let task = Task { await Self.decodeThumbnail(at: url, maxPixelSize: max(size.width, size.height)) }
            inFlight[key] = task
            outcome = await task.value
            // 回到主 actor 之后到这里没有再次挂起，中间不存在"任务已清、缓存未写"
            // 的窗口，所以第三个调用点一定命中缓存或 inFlight，而不是重复解码。
            inFlight[key] = nil
            lastDecodeWasOffMainThread = outcome.ranOffMainThread
            decodeCount += 1
        }

        switch outcome.result {
        case .decoded(let image):
            // 解码**已经跑完**的请求即使被取消，结果也照常入缓存：这份工作已经付过
            // 代价了，丢掉它只会让下次再付一遍（与合成实现同一个口径）。
            cache.store(image, for: asset, tier: tier)
            return .image(image)
        case .missing:
            return .missing
        case .undecodable:
            return .failed(Self.unifiedDecodeFailure)
        }
    }

    // MARK: - 文件头

    /// 一次解码的落点。三种终态，由解码器（非隔离执行器）报回来。
    private struct DecodeOutcome: Sendable {
        enum Result: Sendable {
            /// 拿到了像素。
            case decoded(CGImage)
            /// 文件不在（解码开始前被人删了、或外置卷被拔走）。
            case missing
            /// 文件在，但 ImageIO 读不出像素。
            case undecodable
        }
        let result: Result
        /// 这次解码（或这次判定）是否不在主线程上跑。三种终态都记：
        /// "文件不在"那一次也做了 I/O，也该在非主线程上。
        let ranOffMainThread: Bool
    }

    /// 探针的三态版：`image(for:)` 要区分"文件不在"（`.missing`）和
    /// "文件在但读不出"（`.failed`），而这两个都落进 `facts` 的 `nil` 里。
    private enum ProbeOutcome: Sendable {
        case facts(ImageFileFacts)
        case missing
        case undecodable
    }

    private nonisolated static func probeOutcome(at url: URL) async -> ProbeOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let facts = factsSynchronously(at: url) else { return .undecodable }
        return .facts(facts)
    }

    private nonisolated static func facts(at url: URL) async -> ImageFileFacts? {
        factsSynchronously(at: url)
    }

    /// 读文件头拿固有属性。**不解码像素**：`CGImageSourceCopyPropertiesAtIndex`
    /// 只读元数据——这正是"为了知道尺寸而解码一次"的反面（选档位要先用到尺寸）。
    ///
    /// `nonisolated async`：由全局执行器执行，不占调用方的主 actor。
    /// 读的是文件头不是像素，所以成本是"打开一次文件"这一档，但它在每次
    /// 素材请求和导入时都会被走到，没有理由放在主线程上。
    private nonisolated static func factsSynchronously(at url: URL) -> ImageFileFacts? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        return ImageFileFacts(
            pixelSize: correctedSize(storedWidth: width, storedHeight: height, orientation: orientation),
            exifOrientation: orientation
        )
    }

    /// EXIF 方向 5–8 意味着转了 90°：摆正之后的宽高对调。1–4 只是镜像/翻转，
    /// 尺寸不变。其余值（异常 EXIF）按 1 处理——宁可尺寸差一档，不要除零。
    private nonisolated static func correctedSize(
        storedWidth: Int,
        storedHeight: Int,
        orientation: Int
    ) -> CGSize {
        switch orientation {
        case 5...8:
            return CGSize(width: storedHeight, height: storedWidth)
        default:
            return CGSize(width: storedWidth, height: storedHeight)
        }
    }

    // MARK: - 解码

    /// 解码失败的统一文案（§3.2）：**不去猜**是格式不对还是文件坏了——那都是
    /// ImageIO 的判断，我们只复述结论。猜错文案的代价是用户按着错误的提示
    /// 去修一个修不好的东西。与导入失败（`AssetStore.ImportError.notAnImage`）
    /// 共用，两处才追得上。`nonisolated`：它是纯值，导入错误那边在非隔离
    /// 上下文里也要引用它。
    nonisolated static let unifiedDecodeFailure = "这个文件不是能解码的图片"

    /// 缩略图路径解码：**不整幅解码再缩**（见类型说明）。`nonisolated async`：
    /// 跑在全局执行器上，`pthread_main_np()` 探针把这件事钉成断言。
    ///
    /// `maxPixelSize` 取目标尺寸的最长边：
    ///
    /// - 目标比原图小 → ImageIO 在解码器内部按比例降采样，峰值内存按目标走；
    /// - 目标就是原图（全档）→ `maxPixelSize` 不小于原图最长边，缩略图 API
    ///   按文档返回全尺寸——所以"走缩略图路径"对全档也是成立的，不用分叉。
    private nonisolated static func decodeThumbnail(
        at url: URL,
        maxPixelSize: CGFloat
    ) async -> DecodeOutcome {
        let onMainThread = pthread_main_np() != 0
        // 文件可能在探针之后、解码之前被删掉（访达里删、外置卷拔走）。
        // 这里再认一次，那类情况要落进 `.missing` 而不是 `.failed`。
        guard FileManager.default.fileExists(atPath: url.path) else {
            return DecodeOutcome(result: .missing, ranOffMainThread: !onMainThread)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else {
            return DecodeOutcome(result: .undecodable, ranOffMainThread: !onMainThread)
        }
        let options: [CFString: Any] = [
            // 没有它，缩略图 API 只在"确实需要缩"时才干活。
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            // 方向在解码时消化掉。这个开关是自检用真实 EXIF 文件钉住的（§3.2：
            // 实测而不是按记忆断言）——它不写，画布上摆的就是横躺的图。
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return DecodeOutcome(result: .undecodable, ranOffMainThread: !onMainThread)
        }
        return DecodeOutcome(result: .decoded(image), ranOffMainThread: !onMainThread)
    }
}
