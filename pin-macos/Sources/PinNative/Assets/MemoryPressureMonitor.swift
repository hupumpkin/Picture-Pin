import Dispatch
import Foundation

/// 观察系统内存压力，转成缓存能处理的级别（路线图 §2.3「缓存预算」）。
///
/// ## 为什么监听的是系统压力，而不是自己算
///
/// "我这块占了多少"只有我们自己知道，但"这台机器现在还宽不宽裕"只有系统知道。
/// 自己按进程内存算一个阈值的做法在别的 App 突然要吃内存时完全来不及反应——
/// 那时候我们看到的进程内存一切正常，而机器已经在换页了。
///
/// ## 分级怎么映射
///
/// `DispatchSource` 给的是事件掩码（可能同时带多个位），映射规则收在
/// `pressure(for:)` 里，是个纯函数——真实的内存压力在自检里造不出来
/// （总不能把测试机压到换页），所以**能被断言的部分只有这个映射**，
/// 再往下就是缓存自己的 `handle(_:)`，那条是直接构造事件测的。
@MainActor
final class MemoryPressureMonitor {

    /// 进程级唯一实例。
    ///
    /// 内存压力不是"某个视图"的事，而且监听源挂多了会重复响应（同一级压力
    /// 收到两次就丢两遍缓存——第一次之后本来就空了，第二次纯属浪费）。
    /// 做成单例是为了让"只装一个"成为结构保证。
    static let shared = MemoryPressureMonitor()

    private var source: DispatchSourceMemoryPressure?
    private var handler: ((ImageCache.MemoryPressure) -> Void)?

    /// 收到过几次、分别是什么级别。自检与 B2 报告读它。
    ///
    /// 报告里"这次测量系统有没有报过压力"是一个必须写明的条件（§2.4 要求记录
    /// 缓存冷暖与运行条件）：没报过压力的"内存没有持续增长"和报过之后的，证据
    /// 强度不一样。
    private(set) var deliveries: [ImageCache.MemoryPressure] = []

    private init() {}

    /// 开始监听，并接上处理者。重复调用会替换处理者但**不会叠加监听源**。
    func start(handler: @escaping (ImageCache.MemoryPressure) -> Void) {
        self.handler = handler
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            // 事件处理器跑在主队列上，而主队列就是主 actor 的执行器，所以这里
            // 用 `assumeIsolated` 而不是 `Task { @MainActor }`：后者会把响应推迟
            // 到下一个调度周期，而内存压力要的就是当场丢。
            MainActor.assumeIsolated {
                guard let level = Self.pressure(for: event) else { return }
                self.deliveries.append(level)
                self.handler?(level)
            }
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// 事件掩码 → 级别。纯函数，自检直接喂各种掩码。
    ///
    /// `critical` 优先于 `warning`：两者同时置位时（系统在往下压的过程中会这样）
    /// 要按更严重的那一级处理。
    nonisolated static func pressure(
        for event: DispatchSource.MemoryPressureEvent
    ) -> ImageCache.MemoryPressure? {
        if event.contains(.critical) { return .critical }
        if event.contains(.warning) { return .warning }
        // `.normal` 与空掩码都返回 `nil`：**压力回到正常不是"可以长回去了"**，
        // 见 `ImageCache.handle(_:)` 里"为什么不自动把预算加回去"。
        return nil
    }
}
