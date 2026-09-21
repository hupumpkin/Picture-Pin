import CoreGraphics
import Foundation

/// 已解码图片的共享缓存。
///
/// ## 键是「素材 × 档位」
///
/// 两个维度缺一不可：
///
/// - **按素材**（而不是按元素、也不按画布）：同一张图在画布上出现三次、或者在
///   两块画布上各出现一次，都是同一个缓存条目。按元素存会让"一张素材多次进入
///   画布"（路线图 §5 必测场景）成倍占内存；按画布存则让切画布变成全部重解码。
/// - **按档位**：同一张图的 1/1 和 1/4 是两个条目，缩放来回切换时两边都在，
///   不必反复解码。
///
/// ## 为什么它是独立类型，而不是渲染器里的一个字典
///
/// 因为**只有一个地方知道总共占了多少字节，才谈得上淘汰**。缓存散在多家
/// （渲染器一份、面板一份）时，"预算"这个词就没有意义了——谁都以为自己
/// 只占了一点点。批次 B2 的预算与内存压力处理都从这里长出来。
///
/// 本类型是**纯存储**：不发起解码、不知道素材从哪来。把"读"和"存"分开，
/// 是为了让并发请求的合并（同一张图不会重复解码两次）留在提供者那边——
/// 那是加载策略，不是存储策略。
@MainActor
final class ImageCache {

    /// 缓存键 = 素材 × 档位。**与账本共用同一个类型**：两处各定义一个的话，
    /// "缓存里有这一条"和"图层拿着这一档"就永远对不上号，而那正是缺陷 ③ 的形态。
    typealias Key = ImageResidency.Key

    /// 一条缓存记录的账面占用。
    struct Entry: Equatable {
        let bytes: Int
        let pixelSize: CGSize
    }

    /// 字节预算的上限。默认 512 MB。
    ///
    /// ## 这个数从哪来
    ///
    /// 一张 4K 图解码后是 3840 × 2160 × 4B ≈ 31.6 MB。路线图 §2.4 要求测
    /// 「20 张不同的 4K 图」——**全按原分辨率留着就是 632 MB**，只 20 张。
    /// 所以预算不能拍脑袋定大，LOD 必须真的在省内存。
    ///
    /// 它是**上限**，实际预算取 `defaultByteBudget(forPhysicalMemory:)`：
    /// 内存小的机器上按比例降下来，8 GB 的机器上留 512 MB 给图片缓存是过分的。
    static let maximumByteBudget = 512 * 1024 * 1024

    /// 预算的下限。低于这个值缓存就没有意义了（一张 4K 都放不下）。
    ///
    /// 内存压力把它一路压下来时**以它为底**：压到 0 的表现是"每次重绘都重新
    /// 解码"，那比多占几十兆糟得多——和 `evictIfNeeded` 里"不淘汰最后一条"是
    /// 同一个判断。
    static let minimumByteBudget = 64 * 1024 * 1024

    /// 按物理内存定预算：取 1/8，并夹在上下限之间。
    ///
    /// 1/8 是个粗口径，不是结论——B2 的实测报告里记的是**实测峰值与稳定值**
    /// （路线图 §2.4 要求），这个函数只负责给一个合理的起点。
    static func defaultByteBudget(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let share = Int(clamping: physicalMemory / 8)
        return min(max(share, minimumByteBudget), maximumByteBudget)
    }

    private(set) var byteBudget: Int

    /// 像素驻留账本。缓存自己建一本（**缓存是唯一持有像素的地方**），并通过
    /// `ImageProvider.residency` 交出去给渲染器申报——两边在结构上就是同一个
    /// 实例。账本有两本才会出问题（缺陷 ③ 的形态），而那需要建两个缓存，
    /// 那件事由"缓存要注入、不许各建一个"这条规矩挡着。
    let residency: ImageResidency

    /// 视口外的素材**最多留多少字节**。超出的档位一并不留（`nil` = 一档都不留）。
    ///
    /// §3.9 第 1 条的口径：视口外不留全尺寸，只留一张小到可以忽略的图，
    /// 代价是拖回视口时先糊一下再变清晰。
    ///
    /// ## 为什么用字节而不是"第几档"
    ///
    /// 定档位（"一律留 1/8"）在两种极端上都错：小图（400×225）的 1/8 看不清是
    /// 什么，而它整张全尺寸也才 0.36 MB；4K 的 1/8 是 0.5 MB，但同一张图的
    /// 1/4 也才 2 MB——**一律按档位切，等于把"多大算小"这件事写死在一个与尺寸
    /// 无关的数上**。按字节切，规则只有一句：留一张**便宜**的。
    ///
    /// 4 MB 的取法：4K 的 1/4（960×540）是 2.07 MB、iPhone 截图的 1/4 是
    /// 0.65 MB，都落在里面；而 4K 的全尺寸是 31.6 MB，永远出局——"不留全尺寸"
    /// 这条硬要求由这个数保证。
    ///
    /// ## 留下的这一张是**可牺牲的**
    ///
    /// 它没有任何图层拿着，所以淘汰时排在所有人前面（见 `evictIfNeeded`）：
    /// 内存一紧，先丢的就是这些"糊的底图"，而重做它们的代价是一次小解码。
    /// 这就是为什么"每个看过的素材留一张"不会失控——预算是硬的，它们是最软的。
    var seedByteCeiling: Int? = 4 * 1024 * 1024

    private var entries: [Key: CGImage] = [:]
    private var costs: [Key: Int] = [:]
    /// 最近一次使用的时间戳。用单调计数器而不是 `Date`：同一毫秒内的多次访问
    /// 会撞成相同时间，LRU 就退化成随机淘汰。
    private var lastUsed: [Key: UInt64] = [:]
    private var clock: UInt64 = 0

    // MARK: - 统计（断言与 B2 报告都要读）
    private(set) var hitCount = 0
    private(set) var missCount = 0
    private(set) var evictionCount = 0
    private(set) var storedCount = 0
    /// 账面的历史峰值。报告要的是"峰值 / 稳定值 / 淘汰后值"（路线图 §2.4），
    /// 而峰值**只能边跑边记**：事后再量只能量到当时的存量。
    private(set) var peakTotalBytes = 0
    /// 收到过几次内存压力、各是什么级别。报告要能说清"这次测量里系统到底有没有
    /// 报过压力"——没报过的话，"内存没有持续增长"这句话的证据强度是不一样的。
    private(set) var pressureResponses: [MemoryPressure] = []

    /// 因为"已经离开视口、没人再看"而放掉的档位条数与字节数（§3.9 第 1 条）。
    /// 报告要能说出这一条到底省了多少——否则它只是一个说法。
    private(set) var demotedTierCount = 0
    private(set) var demotedBytes = 0

    init(byteBudget: Int = ImageCache.defaultByteBudget(), residency: ImageResidency = ImageResidency()) {
        self.byteBudget = byteBudget
        self.residency = residency
    }

    // MARK: - 读写

    /// 命中则返回图片并刷新它的使用时间。
    func image(for asset: AssetID, tier: LODTier) -> CGImage? {
        let key = Key(asset: asset, tier: tier)
        guard let image = entries[key] else {
            missCount += 1
            return nil
        }
        hitCount += 1
        clock += 1
        lastUsed[key] = clock
        return image
    }

    /// 只查不改统计，用于断言缓存里有什么。
    func peek(for asset: AssetID, tier: LODTier) -> CGImage? {
        entries[Key(asset: asset, tier: tier)]
    }

    func store(_ image: CGImage, for asset: AssetID, tier: LODTier) {
        let key = Key(asset: asset, tier: tier)
        // 同一张图重复存入时先把旧的账面扣掉，否则重复存会让 totalBytes 虚高，
        // 淘汰会提前触发。
        if costs[key] != nil {
            costs[key] = nil
            entries[key] = nil
            storedCount -= 1
        }
        let bytes = Self.byteCost(of: image)
        entries[key] = image
        costs[key] = bytes
        clock += 1
        lastUsed[key] = clock
        storedCount += 1
        peakTotalBytes = max(peakTotalBytes, totalBytes)
        evictIfNeeded()
    }

    func removeAll() {
        entries.removeAll()
        costs.removeAll()
        lastUsed.removeAll()
        storedCount = 0
    }

    // MARK: - 账面

    var count: Int { entries.count }

    /// **缓存里**这些条目占多少字节。
    ///
    /// 它不等于真实占用：被图层拿着的那些像素即使不在这张表里也还活着。
    /// 报告与预算要看 `residentBytes`；这个数只在自检里用来指认"缓存自己"的账。
    var totalBytes: Int { costs.values.reduce(0, +) }

    /// **真实的像素占用**：缓存里的 ∪ 被图层拿着的，同一个键只算一次。
    ///
    /// 这就是 §2.3「总预算」的口径。两者取并集而不是相加：同一张 `CGImage`
    /// 既在缓存里、又在图层里时只有一份像素，相加会把内存凭空算成两倍。
    ///
    /// 只在图层里、不在缓存里的那些（缓存淘汰过、或存之前图层就先拿到了）
    /// 恰恰是 B2 看不见的那部分，所以并集里必须有它们。
    var residentBytes: Int {
        var total = costs.values.reduce(0, +)
        // 只在图层里、不在缓存里的那些补进来；两边都有的**不重复计**
        // （同一個 `CGImage`，只有一份像素）。
        for (key, bytes) in residency.heldBytes where costs[key] == nil { total += bytes }
        return total
    }

    /// 被图层拿着、但已经不在缓存里的字节数。
    ///
    /// 这是一个**诊断数字**：它大于 0 说明"缓存账面上的占用"低估了真实内存，
    /// 而低估多少一眼可见。B2 的缺陷 ③ 就是让这个数字一直没人知道。
    var layerOnlyBytes: Int {
        residency.heldBytes.reduce(0) { partial, item in
            costs[item.key] == nil ? partial + item.value : partial
        }
    }

    /// 某条记录的大小，供断言核对"档位是否真的省了内存"。
    func entry(for asset: AssetID, tier: LODTier) -> Entry? {
        let key = Key(asset: asset, tier: tier)
        guard let bytes = costs[key], let image = entries[key] else { return nil }
        return Entry(bytes: bytes, pixelSize: CGSize(width: image.width, height: image.height))
    }

    func resetStatistics() {
        hitCount = 0
        missCount = 0
        evictionCount = 0
    }

    /// 一张 `CGImage` 的实际内存占用。定义搬到了 `ImageResidency`——渲染器
    /// 第一个拿到 `CGImage`，它也要算这个数；两处各写一份迟早会分叉。
    static func byteCost(of image: CGImage) -> Int {
        ImageResidency.byteCost(of: image)
    }

    // MARK: - 淘汰

    /// 超出预算就淘汰——**先丢没人拿的**，同组内按最久未用。
    ///
    /// ## 为什么"先丢没人拿的"是这一条的重点
    ///
    /// 按纯 LRU 淘汰一个**正被图层拿着**的条目，一字节都省不下来：像素还在
    /// 图层里（见 `ImageResidency`）。而它恰恰是最容易被误伤的——刚存进来的、
    /// 正在看的图往往就是最"新"的那一条，一轮轮淘汰下去，最后只剩它们在
    /// 互相顶，缓存腾不出空间，解码白做，然后下一次重绘再解一遍。
    ///
    /// 所以排序是两级：**没人拿的在前**，同组内才比最久未用。
    ///
    /// **单张图片本身大于预算时不淘汰它自己**：那会让一张大图永远进不了缓存，
    /// 每次重绘都重新解码——比多占一点内存糟得多。正确的做法是让它留着，
    /// 下一次存入时把别人清掉。
    ///
    /// 一次算出全部要淘汰的，而不是每淘汰一条重算一次最小值：后者是
    /// O(条数²)，而它跑的时机恰好是"刚存进一张大图、缓存已经满了"——
    /// 也就是最不该在主线程上多花时间的时候。见 §2.4 的主线程预算。
    private func evictIfNeeded() {
        var excess = residentBytes - byteBudget
        guard excess > 0 else { return }

        let victims = costs.keys.sorted { lhs, rhs in
            let heldL = residency.isHeld(lhs), heldR = residency.isHeld(rhs)
            if heldL != heldR { return !heldL }
            return (lastUsed[lhs] ?? 0) < (lastUsed[rhs] ?? 0)
        }
        for key in victims {
            guard excess > 0, entries.count > 1 else { break }
            let held = residency.isHeld(key)
            let bytes = costs[key] ?? 0
            entries.removeValue(forKey: key)
            costs.removeValue(forKey: key)
            lastUsed.removeValue(forKey: key)
            evictionCount += 1
            // 被拿着的条目淘汰了也**不省字节**（像素还在图层里），所以不能把它
            // 算进"已经腾出来的量"——算了的话循环会提前收手，账面看着回到预算内、
            // 真实内存纹丝不动。
            if !held { excess -= bytes }
        }
    }

    // MARK: - 视口外不留全尺寸（§3.9 第 1 条）

    /// 某个素材已经**没有图层在看了**：把它没被拿着的高档位放掉，只留最粗的一档。
    ///
    /// ## 为什么需要这一条
    ///
    /// 预算是被动淘汰：只有存入新图时才回收。而"看过多少张图"是没有上限的——
    /// B2 实测的边界正是这个：20 张 4K 全尺寸 632.8 MB > 512 MB 预算，LRU 退化
    /// 成反复重解（20 张里重解了 19 张）。**退出视口的图不该继续占着全尺寸**，
    /// 它们下次被看到可能是一分钟后，也可能是永远。
    ///
    /// ## 代价（产品负责人已知并接受）
    ///
    /// 拖回视口的那一瞬间会先看到一张糊的（图层那边会先贴缓存里剩下的这一张小档），
    /// 目标档解码完再变清晰。换来的是工作集不随"看过多少张"增长。
    ///
    /// ## 为什么留"最便宜的那一档"而不是"最后看的那一档"
    ///
    /// 要留的是**回视口时先贴的那一张**：越小越好用——它只在一瞬间被看到，
    /// 够看清"这是哪张图、大概什么构图"就行。留最后看的那一档等于什么都没省：
    /// 用户多半是在放大的状态下把它拖出视口的，那一档就是全尺寸。
    ///
    /// 留下的那一档还得过 `seedByteCeiling`：最便宜的也超过了上限（比如这张图
    /// 只解过全尺寸），就**一档都不留**——"不留全尺寸"是硬要求，宁可回视口时
    /// 空一下，也不能为了"先贴一张"把 31 MB 的全尺寸留在内存里。
    func demoteUnheldTiers(of asset: AssetID) {
        let candidates = costs.keys.filter { $0.asset == asset }
        guard !candidates.isEmpty else { return }
        // 留哪一档：没人在看的里面**最粗**的那一档（越小越好用，见上面）。写成
        // 显式循环而不是 `filter/max/filter` 串起来：那一串要表达的是"挑一个，
        // 然后因为它不合格而放弃挑"，而链式写法读起来像"在结果上再过滤一次"。
        var keep: Key?
        for key in candidates where !residency.isHeld(key) {
            if let current = keep, current.tier.level >= key.tier.level { continue }
            keep = key
        }
        // 最便宜的那一档也超上限（比如这张图只解过全尺寸）就一档都不留。
        if let key = keep, (costs[key] ?? 0) > (seedByteCeiling ?? 0) { keep = nil }
        for key in candidates where key != keep {
            // 被拿着的**一档都不能动**：那个元素可能正显示着它（同一素材在画布上
            // 出现多次，其中一个离开视口、另一个还在）。
            guard !residency.isHeld(key) else { continue }
            demotedBytes += costs[key] ?? 0
            demotedTierCount += 1
            entries.removeValue(forKey: key)
            costs.removeValue(forKey: key)
            lastUsed.removeValue(forKey: key)
        }
    }

    /// SVG 原件被编辑并回写后，旧的各档位位图都不再可信。这个入口只清缓存
    /// 自己持有的条目；仍被图层持有的那份会在下一次渲染替换时正常释放。
    func invalidateAllTiers(of asset: AssetID) {
        let keys = costs.keys.filter { $0.asset == asset }
        for key in keys {
            entries.removeValue(forKey: key)
            costs.removeValue(forKey: key)
            lastUsed.removeValue(forKey: key)
        }
    }

    /// 同步取一张**已经在内存里**的、不比 `tier` 更细的图。没有就返回 `nil`。
    ///
    /// 取的是"最接近需求的、还留着的那一张"（level 从 `tier.level` 往上找，
    /// 第一个命中的就是）：拖回视口时贴它。**不走统计**（这里不是一次命中，
    /// 是一次探测），也**绝不解码**——它在一次同步扫描里被调用，解码会让
    /// 主线程预算当场破掉（§2.4）。
    func bestAvailableImage(for asset: AssetID, atMost tier: LODTier) -> (image: CGImage, tier: LODTier)? {
        var level = tier.level
        while level <= LODTier.maximumLevel {
            let candidate = LODTier(level: level)
            if let image = entries[Key(asset: asset, tier: candidate)] {
                return (image, candidate)
            }
            level += 1
        }
        return nil
    }

    // MARK: - 内存压力

    /// 系统报来的内存压力级别。
    ///
    /// 用自己的枚举而不是直接收 `DispatchSource.MemoryPressureEvent`：缓存不该
    /// 知道压力是从哪儿报来的，而且这样才能在自检里直接构造事件——真实的系统
    /// 压力在测试里造不出来，造不出来的东西就没法断言。
    enum MemoryPressure: Equatable, Sendable {
        /// 系统内存吃紧。丢掉一部分，别等系统来杀。
        case warning
        /// 系统即将采取行动。除了正在用的，都丢掉。
        case critical

        /// 收到这个级别后预算乘的系数。
        var budgetScale: Double {
            switch self {
            case .warning: return 0.5
            case .critical: return 0.25
            }
        }
    }

    /// 响应内存压力：**先降预算，再按新预算淘汰**。
    ///
    /// ## 为什么不自动把预算加回去
    ///
    /// 系统会报"压力回到正常"，但那句话的意思是"现在不紧张"，不是"你可以再
    /// 长回去"。按它加回去的结果是下次压力来得更晚、更陡。所以收缩是**单向**的，
    /// 恢复靠下次启动。这是刻意的，不是漏了。
    ///
    /// ## 为什么以 `minimumByteBudget` 为底
    ///
    /// 压力连着来的时候预算是 512 → 256 → 128 → 64 → 32…… 一路乘下去，最后
    /// 每次重绘都要重新解码。压到下限就停：宁可多占几十兆，也不要让画布退回
    /// "每帧重新解码"的状态。
    func handle(_ pressure: MemoryPressure) {
        pressureResponses.append(pressure)
        let scaled = Int(Double(byteBudget) * pressure.budgetScale)
        // 底是 64 MB，但**底不能把预算抬起来**：写成 `max(下限, 缩放后的值)` 的话，
        // 一个本来就比下限小的预算（自检里用的就是）会在收到压力的那一刻**变大**
        // ——"收缩是单向的"那句话当场作废。取 `min(当前, 下限)` 当底：
        // 真实预算（≥ 64 MB）行为不变，小的那些只是不再往下压。
        byteBudget = max(min(byteBudget, Self.minimumByteBudget), scaled)
        evictIfNeeded()
        // critical 之后如果还是超（比如只剩一条、而它自己就比预算大），
        // 直接清空：这时候"留着一条大的"已经不是省内存了。
        if pressure == .critical, totalBytes > byteBudget {
            removeAll()
        }
    }
}
