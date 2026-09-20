import CoreGraphics
import Foundation

/// 图片像素的**驻留账本**：每个「素材 × 档位」现在被几个图层拿着。
///
/// ## 为什么要有它（独立复审报回来的缺陷 ③）
///
/// B2 的内存预算只约束 `ImageCache.entries`。可是同一张 `CGImage` 交给
/// `layer.contents` 之后，**图层自己也拿着它**——缓存把那条淘汰掉，像素一字节
/// 都不会少。于是"预算 512 MB"这句话在真实使用里并不成立：看过的图越多、内存
/// 越高，而账本上一片正常。路线图 §2.3 的「总预算」要的是**全部**，这里补上
/// 缺的那一半。
///
/// ## 为什么它是独立类型，而不是缓存里的两张表
///
/// 因为**写它的人和读它的人不是同一个**：
///
/// - **渲染器**知道"这个图层现在铺的是哪一档"——只有它知道；
/// - **缓存**决定淘汰谁、每条占多少字节——也只有它知道。
///
/// 两边的信息都不完整。账本是它们唯一的交汇点：渲染器申报持有，缓存读它决定
/// 淘汰顺序（先丢没人拿的），以及判断某个档位"有没有人在看"（`isHeld`）——
/// 没人在看的那些才放得掉（§3.9 第 1 条：视口外不留全尺寸）。
///
/// ## 一个键只算一份字节
///
/// 两个图层铺同一档时拿的是**同一个 `CGImage` 对象**，像素只有一份。所以字节数
/// 只在第一个持有者进来时记一次——按持有者数重复计费会把内存凭空翻倍，而
/// 由此得出的"超预算"会让淘汰删掉本来够用的东西。
@MainActor
final class ImageResidency {

    struct Key: Hashable {
        let asset: AssetID
        let tier: LODTier
    }

    /// 每个键当前被几个图层拿着。
    private var holders: [Key: Int] = [:]
    /// 每个键的字节数（第一个持有者进来时记下）。
    private var byteSizes: [Key: Int] = [:]

    /// 申报过多少次持有、多少次放手。**两者应当相等**：不相等就是记账漏了，
    /// 而漏一笔的后果正是这一层要修的缺陷。自检拿它做配平断言。
    private(set) var holdCount = 0
    private(set) var releaseCount = 0

    /// 有多少个键现在被拿着。
    var heldKeyCount: Int { holders.count }

    /// 被图层拿着的总字节数。**它加上缓存里没被拿的那些**才是真实占用。
    var heldTotalBytes: Int { byteSizes.values.reduce(0, +) }

    /// 正在被拿着的键与各自的字节数。缓存算"总占用"时用它去重。
    var heldBytes: [Key: Int] { byteSizes }

    /// 这个键现在有人拿着吗。
    func isHeld(_ key: Key) -> Bool { holders[key] != nil }

    /// 申报：某个图层开始铺这一档的像素。
    func hold(_ key: Key, bytes: Int) {
        holdCount += 1
        let count = (holders[key] ?? 0) + 1
        holders[key] = count
        if count == 1 { byteSizes[key] = bytes }
    }

    /// 申报：某个图层不再铺这一档了。
    ///
    /// **只记事实，不做决定。** "已经没人拿着了"之后要不要放掉像素，是缓存的
    /// 策略（§3.9 第 1 条），由拿着像素的那一方在明确的位置决定——这里发一个
    /// 隐式回调出去的话，"为什么这张图忽然要重解码"就变成了一条看不见的因果链。
    ///
    /// 放手**多于持有**时什么都不做（不把计数做成负数）：那说明记账本身错了，
    /// 而负数会一路传染到淘汰逻辑里，变成"预算算出来是负的、于是谁都不淘汰"。
    func release(_ key: Key) {
        guard let count = holders[key] else { return }
        releaseCount += 1
        if count <= 1 {
            holders.removeValue(forKey: key)
            byteSizes.removeValue(forKey: key)
        } else {
            holders[key] = count - 1
        }
    }

    /// 一张 `CGImage` 的实际内存占用。
    ///
    /// 用 `bytesPerRow × height` 而不是 `width × height × 4`：前者是 CoreGraphics
    /// 真正分配的行宽（可能带对齐填充），后者是我们**希望**它占的。预算按愿望算
    /// 的话会低估，内存压力就来得比预期早。
    ///
    /// 定义在这里而不是缓存里：它是"拿着这份像素要多少内存"，属于驻留这件事，
    /// 渲染器也要用它（它才是第一个拿到 `CGImage` 的人）。
    static func byteCost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }
}
