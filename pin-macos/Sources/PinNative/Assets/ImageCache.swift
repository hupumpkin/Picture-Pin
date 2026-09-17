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

    struct Key: Hashable {
        let asset: AssetID
        let tier: LODTier
    }

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

    init(byteBudget: Int = ImageCache.defaultByteBudget()) {
        self.byteBudget = byteBudget
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

    var totalBytes: Int { costs.values.reduce(0, +) }

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

    /// 一张 `CGImage` 的实际内存占用。
    ///
    /// 用 `bytesPerRow × height` 而不是 `width × height × 4`：前者是 CoreGraphics
    /// 真正分配的行宽（可能带对齐填充），后者是我们**希望**它占的。
    /// 预算按愿望算的话会低估，内存压力就来得比预期早。
    static func byteCost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    // MARK: - 淘汰

    /// 超出预算就按最久未用淘汰。
    ///
    /// **单张图片本身大于预算时不淘汰它自己**：那会让一张大图永远进不了缓存，
    /// 每次重绘都重新解码——比多占一点内存糟得多。正确的做法是让它留着，
    /// 下一次存入时把别人清掉。
    ///
    /// 一次算出全部要淘汰的，而不是每淘汰一条重算一次最小值：后者是
    /// O(条数²)，而它跑的时机恰好是"刚存进一张大图、缓存已经满了"——
    /// 也就是最不该在主线程上多花时间的时候。见 §2.4 的主线程预算。
    private func evictIfNeeded() {
        var excess = totalBytes - byteBudget
        guard excess > 0 else { return }

        // 按最久未用排序，从最旧的开始丢，直到够为止。
        let victims = lastUsed.sorted { $0.value < $1.value }.map(\.key)
        for key in victims {
            guard excess > 0, entries.count > 1 else { break }
            excess -= costs[key] ?? 0
            entries.removeValue(forKey: key)
            costs.removeValue(forKey: key)
            lastUsed.removeValue(forKey: key)
            evictionCount += 1
        }
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
