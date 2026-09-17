import Foundation
import os

/// 性能埋点。服务于 `--perf-report`（路线图 §2.4 要求"用 Instruments 和 signpost
/// 记录"），不是产品逻辑。
///
/// ## 为什么是全局静态，而不是注入进渲染器
///
/// 把探针做成依赖注入，每个构造点都得记得接线，而漏掉的表现是**报告里少一栏
/// 数字**——读代码看不出来，也永远不会报错。全局静态没有"忘了接线"这种失败模式。
///
/// 代价是它必须**零开销地关着**：`isEnabled` 为假时只有一次布尔判断，符号与
/// 字符串都不碰。默认就是关的（`--selftest` 与正常启动都不打开）。
///
/// ## 数字的口径（这一节比代码重要）
///
/// 这里量到的全是**主线程上的工作耗时**：一次输入事件的处理、一遍可见性扫描、
/// 一次图层提交。它们**不是帧率**：
///
/// - 没有窗口时根本没有"呈现"这件事，`CATransaction.commit()` 只是把图层改动
///   写进渲染树，真正的合成在窗口进程（WindowServer）里，这里量不到。
/// - 有窗口时，主线程工作耗时也只是帧时间的**一部分**：合成、显示链路、垂直同步
///   都在别处。报告里写的必须是"每帧主线程工作耗时"，不能写成"帧时间"。
@MainActor
enum PerformanceProbe {

    /// 关着的时候一切照旧，只是不记账。
    static var isEnabled = false

    /// Instruments 的 signpost。subsystem 用 Bundle ID 的稳定写法，
    /// 这样"PinNative"这个名字改了也不会让 Instruments 里的记录断掉。
    private static let signposter = OSSignposter(
        subsystem: "com.pin.native.canvas",
        category: .pointsOfInterest
    )

    /// 各段耗时（毫秒），按名字分组。
    static private(set) var durations: [String: [Double]] = [:]
    /// 各类事件发生次数。
    static private(set) var counters: [String: Int] = [:]

    static func reset() {
        durations.removeAll()
        counters.removeAll()
    }

    /// 量一段同步代码。返回闭包的返回值，调用点不必为埋点改结构。
    @discardableResult
    static func measure<T>(_ name: StaticString, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        // 名字取 `StaticString` 而不是 `String`：`beginInterval` 只收前者。
        // 这不是将就——埋点名字本来就该是编译期常量，段名是可枚举的有限几个。
        let key = "\(name)"
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            durations[key, default: []].append(
                Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            )
            signposter.endInterval(name, state)
        }
        return body()
    }

    /// 记一次事件。分类是字符串，因为报告要按名字把它们列出来。
    static func count(_ name: StaticString, by amount: Int = 1) {
        guard isEnabled else { return }
        counters["\(name)", default: 0] += amount
    }

    static func samples(_ name: String) -> [Double] { durations[name] ?? [] }
    static func counter(_ name: String) -> Int { counters[name] ?? 0 }

    /// 分位数（线性插值）。样本为空时返回 0。
    ///
    /// 报告要的是中位数 / P95 / P99（§2.4 的原话），所以这三个数直接由它算出来，
    /// 手算的百分位法在样本少时会明显不同——同一份报告里必须只有一种算法。
    static func percentile(_ fraction: Double, of samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        guard fraction > 0 else { return sorted[0] }
        guard fraction < 1 else { return sorted[sorted.count - 1] }
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    /// 超过给定预算的次数（§2.4 的"卡顿次数"：60Hz 16.7ms、120Hz 8.3ms）。
    static func overBudget(_ samples: [Double], milliseconds: Double) -> Int {
        samples.filter { $0 > milliseconds }.count
    }
}

// MARK: - 进程内存

/// 进程的常驻内存（RSS）。报告里"验证无持续增长"读的就是它。
///
/// 用 `task_info` 而不是 `ProcessInfo`：后者没有 RSS 这一项。取值失败返回 `nil`，
/// 调用方必须**把"量不到"写进报告**，不能拿 0 顶上（0 会被读成"内存很小"）。
func residentMemoryBytes() -> Int? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.resident_size) : nil
}
