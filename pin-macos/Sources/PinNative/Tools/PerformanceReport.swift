import AppKit
import CoreGraphics
import Foundation

/// B2 的实测报告（路线图 §2.4）。
///
/// ## 为什么它必须存在，而不是"跑一次 Instruments 截个图"
///
/// §2.4 要的数字里有几项**只有代码能产生**：
///
/// - 缓存的历史峰值（事后再量只能量到当时的存量，峰值必须边跑边记）；
/// - 淘汰次数、解码次数、命中率；
/// - 「移出视口再移回来有没有重新解码」——那是一次**没发生**的解码，
///   时间轴上留不下痕迹。
///
/// 反过来，Instruments 看得见的那些东西这里看不见：**没有窗口时不存在"呈现"**，
/// `CATransaction.commit()` 只是把图层改动写进渲染树，真正的合成在 WindowServer
/// 里。所以两者的分工要写在报告里，不能含糊：这里给的是**每帧主线程工作耗时**，
/// 帧节奏与 GPU 占用由 Instruments 补（那一步是人工跑，本文件不假装做过）。
///
/// ## 数字的口径（这一节比代码重要）
///
/// `input` 是每帧的**外层**耗时：一次输入事件走完「输入 → 档位 → 图层提交」。
/// `scan` / `commit` / `commit.camera` 是它的**内层分解**——**包含关系，不是相加
/// 关系**。报告里必须这么写：把分解项加起来当帧时间是这份报告最容易犯的错。
///
/// 跑法：`swift run -c release PinNative --perf-report`
///
/// release 才有意义：debug 的 `-Onone` 会让这些数字整体偏大一个量级，而 §2.4 的
/// 预算是按用户实际拿到的构建算的。
@MainActor
enum PerformanceReport {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--perf-report")
    }

    /// 上报口径的画布尺寸。
    ///
    /// **从设计令牌推导**，不写死：素材面板宽度是可拖的（`DesignTokens.Metrics`），
    /// 写死的话报告说的就不是当前布局下的画布。窗口默认 1280×800
    /// （`PinNativeApp.defaultSize`），左侧浮层面板占 `panelWidth + inset × 2`。
    private static var canvasViewportSize: CGSize {
        CGSize(
            width: 1280 - (DesignTokens.Metrics.panelWidth + DesignTokens.Metrics.floatingPanelInset * 2),
            height: 800
        )
    }

    // MARK: - 入口

    static func runAndExit() async -> Never {
        // 进程入口的第一件事。dyld 与静态初始化已经发生，所以这是「进程启动」的
        // 一个**偏乐观**的近似——报告里把它拆成两段，不合并成一个数。
        let processStart = DispatchTime.now()

        // 离屏也要有 NSApplication：没有它，`NSScreen` 取不到值，
        // 图层与颜色的解析在某些系统版本上会静默失败（`SnapshotHarness` 同理）。
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let appKitReady = DispatchTime.now()

        PerformanceProbe.isEnabled = true

        print("")
        print("Pin 原生画布 · B2 性能实测报告（路线图 §2.4）")
        print("命令：swift run -c release PinNative --perf-report")
        print("时间：\(ISO8601DateFormatter().string(from: Date()))")
        print("")

        let headerStart = DispatchTime.now()
        printEnvironment()
        reportHeaderCost = since(headerStart)

        await startupScenario(processStart: processStart, appKitReady: appKitReady)
        await panScenario(elementCount: 300, assets: 3, label: "300 元素 · 混合素材")
        await panScenario(elementCount: 1000, assets: 3, label: "1000 元素 · 混合素材")
        await allVisibleScenario(elementCount: 1000)
        await ultraHDRoundTripScenario()
        await hysteresisBoundaryScenario()
        await memoryPressureScenario()

        printBoundaries()

        // 退出前把探针关掉：`exit` 之后的清理路径不该走到埋点里。
        PerformanceProbe.isEnabled = false
        exit(0)
    }

    // MARK: - 打印小工具

    private static func section(_ title: String) {
        print("")
        print("── \(title) " + String(repeating: "─", count: max(0, 58 - title.count)))
    }

    private static func number(_ value: Double, digits: Int = 2) -> String {
        String(format: "%.\(digits)f", value)
    }

    private static func milliseconds(_ value: Double) -> String {
        "\(number(value, digits: 3)) ms"
    }

    private static func megabytes(_ bytes: Int) -> String {
        "\(number(Double(bytes) / 1024 / 1024, digits: 1)) MB"
    }

    private static func since(_ start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    /// 一段耗时的完整分布。§2.4 要的是中位数 / P95 / P99，最大值为的是看尾部。
    private static func distribution(_ samples: [Double]) -> String {
        guard !samples.isEmpty else { return "无样本" }
        return "中位数 \(milliseconds(PerformanceProbe.percentile(0.5, of: samples)))"
            + " · P95 \(milliseconds(PerformanceProbe.percentile(0.95, of: samples)))"
            + " · P99 \(milliseconds(PerformanceProbe.percentile(0.99, of: samples)))"
            + " · 最大 \(milliseconds(samples.max() ?? 0))"
    }

    /// 卡顿次数。§2.4 给的两个参照：60Hz 一帧 16.7ms、120Hz 一帧 8.3ms。
    ///
    /// **它不是掉帧数**：这里的样本是主线程工作耗时，不含合成与显示链路，
    /// 所以「超过 8.3ms」只说明这一帧的主线程工作吃掉了一整个 120Hz 帧的时间预算，
    /// 不等于用户看到了一次卡顿。报告里的话必须这么写。
    private static func hitches(_ samples: [Double]) -> String {
        guard !samples.isEmpty else { return "无样本" }
        return ">16.7ms \(PerformanceProbe.overBudget(samples, milliseconds: 16.7)) 次"
            + " · >8.3ms \(PerformanceProbe.overBudget(samples, milliseconds: 8.3)) 次"
            + "（共 \(samples.count) 帧）"
    }

    private static func cacheLine(_ cache: ImageCache) -> String {
        "命中 \(cache.hitCount) · 未命中 \(cache.missCount) · 淘汰 \(cache.evictionCount)"
            + " · 存量 \(megabytes(cache.totalBytes))"
    }

    /// 按**显示宽度**补空格。`padding(toLength:)` 数的是 UTF-16 单元，而中日韩
    /// 字符占两个格子——用它对齐会得到一列参差不齐的标签，报告里两行数据看着
    /// 像是错开的。
    private static func pad(_ text: String, to width: Int) -> String {
        let displayWidth = text.unicodeScalars.reduce(0) { total, scalar in
            total + (scalar.value > 0x2E80 ? 2 : 1)
        }
        return text + String(repeating: " ", count: max(1, width - displayWidth))
    }

    private static func tierName(_ tier: LODTier?) -> String {
        guard let tier else { return "取不到" }
        return tier.level == 0 ? "原分辨率" : "1/\(1 << tier.level)"
    }

    // MARK: - 环境

    /// 表头与机器信息打印本身的耗时。计算启动分段时扣掉：它是这份报告的开销，
    /// 不属于任何一次真实启动。
    private static var reportHeaderCost: Double = 0

    private static func printEnvironment() {
        section("1 环境")

        let info = ProcessInfo.processInfo
        print("  芯片            \(sysctlString("machdep.cpu.brand_string") ?? "取不到")")
        print("  物理内存        \(megabytes(Int(clamping: info.physicalMemory)))")
        print("  系统            \(info.operatingSystemVersionString)")
        print("  构建模式        \(buildMode)")

        if let screen = NSScreen.main {
            print("  显示器          \(screen.localizedName)"
                + " · \(Int(screen.frame.width))×\(Int(screen.frame.height)) 点"
                + " · 缩放 \(number(Double(screen.backingScaleFactor), digits: 1))×"
                + " · 刷新率 \(refreshRateDescription())")
        } else {
            // 取不到就写取不到。拿一个默认值顶上会让报告在最需要它的时候
            // 给出一个看起来正常、实际不是本机的数字。
            print("  显示器          取不到（离屏且未连接 WindowServer 会话）")
        }

        let viewport = canvasViewportSize
        print("  屏幕倍率        \(number(Double(displayScale), digits: 1))×"
            + (NSScreen.main == nil ? "（显示器取不到，退回 2——报告里的像素需求按这个算）" : ""))
        print("  窗口           1280×800 点（`PinNativeApp.defaultSize`）")
        print("  画布视口        \(Int(viewport.width))×\(Int(viewport.height)) 点"
            + "（已扣掉左侧浮层面板 \(Int(DesignTokens.Metrics.panelWidth)) + 内边距）")
        print("  玻璃面板        常开（`UI/GlassSurface.swift`，没有开关）。"
            + "本报告离屏，材质合成在主线程之外也量不到——见第 8 节")
        let motion = MotionConfiguration.default
        print("  预加载边距      \(Int(motion.viewport.preloadMargin)) 点"
            + "（视口虚拟化的外扩量）")
        print("  迟滞系数        \(number(Double(motion.lod.downgradeHeadroom), digits: 3))"
            + "（`lod.downgradeHeadroom`；1 等于无迟滞）")
        print("  缓存预算        \(megabytes(ImageCache.defaultByteBudget()))"
            + "（物理内存 1/8，夹在 \(megabytes(ImageCache.minimumByteBudget))"
            + " ~ \(megabytes(ImageCache.maximumByteBudget)) 之间）")
        print("  素材            程序合成（`SyntheticImageProvider`）："
            + "3840×2160 / 3456×2234 / 1170×2532，不读磁盘、不碰真实图库")
        print("  计时器          `DispatchTime.now().uptimeNanoseconds`"
            + "（单调时钟，不受系统时间调整影响）")
    }

    /// 上报口径的屏幕倍率。取真实显示器；取不到时退回 2 并在报告里写明。
    ///
    /// 写死 2 会让报告在 1× 外接屏上给出一个"图比实际清楚一倍"的假象——
    /// 而档位需求里乘的正是这个数。
    private static var displayScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }

    private static var buildMode: String {
        #if DEBUG
        "debug（-Onone，数字整体偏大，§2.4 的预算不按这个口径）"
        #else
        "release"
        #endif
    }

    private static func refreshRateDescription() -> String {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return "取不到" }
        let rate = mode.refreshRate
        // 0 是"系统没报"，不是"0Hz"。写 0 会被读成测量失败，所以分开写。
        return rate > 0 ? "\(number(rate, digits: 1)) Hz" : "系统未报告（ProMotion 自适应档常见）"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - 场景一：空画布启动

    /// §2.4 的目标：空画布启动 < 800ms。
    ///
    /// ## 为什么拆成两段
    ///
    /// 量到的是「**进程入口 → 空画布的首次图层提交**」，它里面混着三件不相干的事：
    /// dyld 与静态初始化、`NSApplication` 连 WindowServer、以及画布自己。
    /// 合成一个数的话，画布变慢和启动环境变慢就分不开了——而那两件事的处置
    /// 完全不同。所以拆成两段报，并说明第三件事（SwiftUI 场景、存储准备、
    /// 窗口创建、首帧合成与上屏）在这里**根本不存在**：本进程没有窗口。
    ///
    /// 这个数是启动耗时的**下界**，不能拿它宣布"启动达标"。
    private static func startupScenario(processStart: DispatchTime, appKitReady: DispatchTime) async {
        section("2 空画布启动")

        let canvasStart = DispatchTime.now()
        let coordinator = CanvasHostView.Coordinator(
            camera: .initial,
            scene: CanvasScene(),
            selection: [],
            configuration: .default,
            images: SyntheticImageProvider(assets: []),
            commands: CanvasCommandRelay(),
            onSceneChange: { _ in },
            onSelectionChange: { _ in },
            onCameraChange: { _ in }
        )
        let view = CanvasHostNSView(frame: CGRect(origin: .zero, size: canvasViewportSize))
        coordinator.attach(to: view)
        // 走一次布局 + 相机写入：真实启动里这两件事由 SwiftUI 的首次布局触发。
        coordinator.updateViewport(size: canvasViewportSize, backingScaleFactor: displayScale)
        // 到这里首次图层提交已经发生（`updateViewport` → 相机写入 → 扫描 → 提交）。
        // **计时到此为止**：下面那个 `drain()` 里含着 150ms 的故意空闲，是测量脚手架
        // 在等异步工作落地，把它算进"画布建立"会让这个数虚高一个量级。
        let canvasCost = since(canvasStart)
        await drain()

        let toAppKit = Double(appKitReady.uptimeNanoseconds - processStart.uptimeNanoseconds) / 1_000_000
        print("  ① 进程入口 → AppKit 就绪   \(milliseconds(toAppKit))")
        print("     （dyld、静态初始化、`NSApplication` 连 WindowServer）")
        print("  ② 机器信息读取与本报告表头 \(milliseconds(reportHeaderCost))（报告自身开销，不计入启动）")
        print("  ③ 画布建立 → 首次图层提交   \(milliseconds(canvasCost))")
        print("     （协调器 + 渲染器 + 宿主视图 + 首次布局与提交；空场景，0 个元素）")
        print("  ①+③ 合计                   \(milliseconds(toAppKit + canvasCost))"
            + "   （§2.4 目标 800ms）")
        print("  建了图层的元素             \(coordinator.materializedElementCount)")
        print("  **不含**：SwiftUI 场景建立、存储准备、窗口创建、首帧合成与上屏——"
            + "本进程没有窗口，这几项在这里不存在。这个数是启动耗时的下界")
    }

    // MARK: - 场景二：平移（部分可见）

    private struct SweepResult {
        var frames = 0
        var input: [Double] = []
        var scan: [Double] = []
        var cameraCommit: [Double] = []
        var sceneCommit: [Double] = []
        var materializedPeak = 0
        var footprintPeak = 0
        // 这一遍自己的缓存账。**随结果一起带走、由 `report` 打印**：留在 `sweep`
        // 里打印的话，这行字会落在它所归属的那个标题**上面**——读起来像是上一段
        // 的结论，而它其实是下一段的。第一版就是这么错的，还会让人以为"首扫一次
        // 都没解码"。
        var decodeDelta = 0
        var cancelDelta = 0
        var hits = 0
        var misses = 0
        var evictions = 0
        var storedBytes = 0
    }

    private static func panScenario(elementCount: Int, assets assetCount: Int, label: String) async {
        section("3 \(label) · 平移")

        let viewport = canvasViewportSize
        let assets = SyntheticImageProvider.makeAssets(count: assetCount)
        let grid = makeGrid(
            elementCount: elementCount,
            columns: 25,
            cell: CGSize(width: 200, height: 150),
            spacing: CGSize(width: 60, height: 60),
            assets: assets
        )
        let cache = ImageCache()
        let provider = SyntheticImageProvider(assets: assets, cache: cache)
        let coordinator = makeCoordinator(scene: grid.scene, provider: provider, viewport: viewport)
        await drain()

        // 沿着网格最上一行走一遍。横向扫是浏览素材最常见的动作，也会让
        // "进视口 / 出视口"这两件事反复发生——虚拟化的效果就在这条路上。
        let start = CGPoint(x: viewport.width / 2, y: grid.frames[0].midY)
        let step: CGFloat = 16
        let travel = grid.size.width
        let frames = Int((travel / step).rounded()) + 1

        print("  网格              \(elementCount) 个元素 · \(grid.columns) 列 ·"
            + " 世界范围 \(Int(grid.size.width))×\(Int(grid.size.height))")
        print("  素材              \(assetCount) 种（每个元素 200×150 世界单位）")
        print("  每帧位移          \(number(Double(step), digits: 0)) 点 · 共 \(frames) 帧")

        // 首扫：沿途大多数元素是**第一次**进视口，所以这一遍包含解码。
        //
        // 方向：`Camera.translate(byViewDelta:)` 是 `center -= delta / zoom`，
        // 所以往 +x 扫要靠**负**的视图增量。写正号的话相机会一路开到网格外面，
        // 测出来的是一条空跑曲线——而且看起来完全正常。
        let cold = await sweep(
            coordinator: coordinator,
            start: start,
            delta: CGSize(width: -step, height: 0),
            frames: frames,
            cache: cache,
            provider: provider,
            clearCacheFirst: true
        )
        report(sweep: cold, title: "首扫（出发前清空缓存）")

        // 回扫：原路返回，像素已经在缓存里。这一遍量的才是**纯主线程工作**——
        // §2.4 的 8ms 预算该按这一组看。
        let warm = await sweep(
            coordinator: coordinator,
            start: CGPoint(x: start.x + travel, y: start.y),
            delta: CGSize(width: step, height: 0),
            frames: frames,
            cache: cache,
            provider: provider
        )
        report(sweep: warm, title: "回扫（像素已在缓存）")
        print("     首扫 vs 回扫   解码次数是这两组唯一的差别——"
            + "元素数、帧数、位移完全相同，所以差异只可能来自像素在不在缓存里")
    }

    /// 1000 个元素**全部可见**：虚拟化救不了的那一组。
    ///
    /// 这一组是必要的对照。只测"部分可见"的话，屏幕上永远只有十来个图层，
    /// 得出的数字会让人以为 1000 元素的画布很轻松——而用户缩到能看见全部内容
    /// 的那一刻，1000 个图层就同时在树上了。§2.4 要的是这个上限。
    private static func allVisibleScenario(elementCount: Int) async {
        section("4 \(elementCount) 元素 · 全部可见（上限对照）")

        let viewport = canvasViewportSize
        let assets = SyntheticImageProvider.makeAssets(count: 3)
        let grid = makeGrid(
            elementCount: elementCount,
            columns: 25,
            cell: CGSize(width: 200, height: 150),
            spacing: CGSize(width: 60, height: 60),
            assets: assets
        )
        let cache = ImageCache()
        let provider = SyntheticImageProvider(assets: assets, cache: cache)
        let coordinator = makeCoordinator(scene: grid.scene, provider: provider, viewport: viewport)

        // 缩到全部内容进视口。留 5% 余量，免得最外圈恰好压着边界——
        // 那样"全部可见"就成了一个随浮点噪声翻转的判据。
        let fit = min(
            viewport.width / (grid.size.width * 1.05),
            viewport.height / (grid.size.height * 1.05)
        )
        var camera = coordinator.camera
        camera.setZoom(fit)
        camera.center = CGPoint(x: grid.size.width / 2, y: grid.size.height / 2)
        coordinator.camera = camera
        await drain()

        print("  缩放              \(number(Double(fit), digits: 4))（内容刚好铺满视口）")
        print("  建了图层的元素    \(coordinator.materializedElementCount) / \(elementCount)")

        // 位移**刻意很小**（1 视图点/帧）：这一组的前提是"1000 个图层全在树上"，
        // 位移一大，后半程就有元素滑出视口、图层被丢掉，测的就不再是上限了。
        // 1 点/帧 × 120 帧 = 120 视图点，在 0.09 倍下约 1300 世界单位，
        // 远小于可见半宽——全程 1000 个图层都还在。
        let step: CGFloat = 1
        let frames = 120
        let result = await sweep(
            coordinator: coordinator,
            start: CGPoint(x: camera.center.x, y: camera.center.y),
            delta: CGSize(width: -step, height: 0),
            frames: frames,
            cache: cache,
            provider: provider
        )
        report(sweep: result, title: "低倍率平移（\(frames) 帧）")
        print("     终点建层数     \(coordinator.materializedElementCount) / \(elementCount)"
            + "（仍是全部可见，否则这一组就不是上限了）")
        print("     说明           这一组里「档位变更 0 次、发出请求 0 次」是对的："
            + "1000 个元素只用了 3 张素材、全程同一档，")
        print("                    所以没有任何一次请求穿透到缓存——缓存统计因此是 0。"
            + "这正是「档位和素材都没变就不发请求」生效的样子。")
    }

    // MARK: - 场景三：20 张 4K · 20% ↔ 200% 往返

    /// §2.4 原文要的场景。这里测的是**内存**，不是时间。
    ///
    /// ## 两件必须说清楚的事
    ///
    /// **一、为什么要"走遍"而不是"一次性显示 20 张"。** 一张 4K 在 200% 下宽
    /// 3840 点，20 张摆在 200% 下是看不全的，所以"一次性把 20 张全解出来"这个
    /// 场景在虚拟化生效之后**根本不会发生**——这恰恰是虚拟化该有的样子。要测
    /// 缓存的上限，只能让相机走遍全部 20 张：每一张都真的解码过一次，缓存里
    /// 于是真的躺过 20 张 4K。
    ///
    /// **二、为什么内存要看两个数。** `phys_footprint` / `resident_size`
    /// **不计**未被触碰的 purgeable 页，而 CoreGraphics 位图上下文的字节正是
    /// 这么分配的。同机实测（见 `touchedFootprint` 的注释）：16 张 4K 刚造出来时
    /// footprint 只有 2 MB，逐张 `draw` 一次之后立刻变成 509 MB——而账面是 506 MB。
    /// 所以**"进程才 36 MB，所以缓存没占内存"这句话是错的**，是量具看不见它。
    /// 两个数都报，并说明哪个才是缓存真正占着的。
    private static let elementCountForThrashNote = 20

    private static func ultraHDRoundTripScenario() async {
        section("5 20 张 4K · 200% 走遍全部 → 20% → 回到 200%")

        let viewport = canvasViewportSize
        let assets = SyntheticImageProvider.makeUniform4KAssets(count: 20)
        // 世界尺寸取原图的一半：200% 下正好是原分辨率，需求落回 0 档（全尺寸）。
        let grid = makeGrid(
            elementCount: 20,
            columns: 5,
            cell: CGSize(width: 1920, height: 1080),
            spacing: CGSize(width: 240, height: 240),
            assets: assets
        )
        let cache = ImageCache()
        let provider = SyntheticImageProvider(assets: assets, cache: cache)
        let coordinator = makeCoordinator(scene: grid.scene, provider: provider, viewport: viewport)

        let bytesPerFullImage = 3840 * 2160 * 4
        print("  单张 4K 解码后    \(megabytes(bytesPerFullImage))（3840×2160×4B，账面值）")
        print("  20 张全尺寸合计   \(megabytes(bytesPerFullImage * 20))"
            + "   预算 \(megabytes(cache.byteBudget)) → 装不下，下面记的就是这件事")

        // **走遍是程序化相机移动，不是手势**：一张 4K 在 200% 下宽 3840 点，
        // 任何真实的滚动事件都跨不过它，硬造一个每帧几千点的增量只会得到一条
        // 没有对应场景的曲线。相机直接写入走的是同一条
        // `adoptCamera` → 可见性 + 档位重算的路径，虚拟化该做的事一件不少。
        func jump(to frame: CGRect, zoom: CGFloat) {
            var next = coordinator.camera
            next.setZoom(zoom)
            next.center = CGPoint(x: frame.midX, y: frame.midY)
            coordinator.camera = next
        }
        func walkAll(zoom: CGFloat) async {
            for (index, frame) in grid.frames.enumerated() {
                jump(to: frame, zoom: zoom)
                await drain(index == 0 ? 150_000_000 : 60_000_000)
            }
        }

        await walkAll(zoom: 2)
        print("")
        print("  ① 200% 走遍 20 张")
        print("     解码次数       \(provider.decodeCount)（20 张各一次；虚拟化下只有"
            + "真正进过视口的才解）")
        print("     取消次数       \(provider.cancelledBeforeDecodeCount)"
            + "（在解码开始之前被顶掉——这些解码没有发生）")
        print("     缓存账面峰值   \(megabytes(cache.peakTotalBytes))")
        print("     缓存淘汰次数   \(cache.evictionCount)")
        print("     进程 footprint \(megabytes(footprintBytes()))"
            + " · 读写之后 \(megabytes(touchedFootprint(cache: cache, assets: assets)))")
        print("                     （前者**看不见**未被触碰的 purgeable 页；"
            + "后者才是缓存真正占着的量级，见第 8 节第 6 条）")

        // ② 缩到 20%。相机停在**网格中央那张**上缩，这样两件事同时成立：
        //
        // - 它在缩放前后**都可见**，所以迟滞对它成立（有"上一档"可比）；
        // - 缩到 20% 之后整个网格都进视口，20 张全部可见。
        //
        // 停在角落那张上缩的话，20% 下只能看见 9 张——那样"全部可见"这句话
        // 就是错的，而档位那一栏也量不到东西。
        let rows = (grid.frames.count + grid.columns - 1) / grid.columns
        let stayIndex = (rows / 2) * grid.columns + grid.columns / 2
        let stayFrame = grid.frames[stayIndex]
        let stayID = grid.ids[stayIndex]

        jump(to: stayFrame, zoom: 2)
        await drain()
        let tierBeforeZoomOut = coordinator.renderedTier(of: stayID)
        let decodedBefore = provider.decodeCount
        cache.resetStatistics()

        jump(to: stayFrame, zoom: 0.2)
        let settle = await settledTier(coordinator: coordinator, id: stayID)
        let settledTier = settle.tier
        // "重新进视口"的那张：缩放后才第一次拿到图层，因此没有上一档。
        let reenteredID = grid.ids.first { $0 != stayID && coordinator.renderedTier(of: $0) != nil }
        let reenteredTier = reenteredID.flatMap { coordinator.renderedTier(of: $0) }
        let noHysteresis = LODTier.fitting(
            CGSize(width: stayFrame.width * 0.2 * displayScale,
                   height: stayFrame.height * 0.2 * displayScale),
            original: grid.assets[0].pixelSize
        )
        let stayOriginal = grid.assets[stayIndex % grid.assets.count].pixelSize
        func bytes(of tier: LODTier) -> Int {
            let size = tier.pixelSize(forOriginal: stayOriginal)
            return Int(size.width) * Int(size.height) * 4
        }

        print("")
        print("  ② 缩到 20%（相机停在网格中央那张上，20 张这时全部可见）")
        print("     建了图层的元素      \(coordinator.materializedElementCount) / 20")
        let demand = CGSize(width: stayFrame.width * 0.2 * displayScale,
                            height: stayFrame.height * 0.2 * displayScale)
        print("     需求                \(Int(demand.width))×\(Int(demand.height)) 像素"
            + "（元素 \(Int(stayFrame.width))×\(Int(stayFrame.height)) 世界单位 × 0.2 × "
            + "屏幕倍率 \(number(Double(displayScale), digits: 1))）")
        print("     第 \(stayIndex) 张（全程可见）档位 \(tierBeforeZoomOut.map { tierName($0) } ?? "取不到")"
            + " → \(settle.trajectory.joined(separator: " → "))"
            + (settle.converged ? "（收敛）" : "（**未收敛**，已到轮数上限）"))
        print("     另一张（重新进视口） 档位 \(tierName(reenteredTier))"
            + "   ← 缩放后才有图层，没有上一档，等于「刚好覆盖需求」")
        print("     对照                 全程可见那张若不做迟滞会是 \(tierName(noHysteresis))"
            + "（`LODTier.fitting`：最粗的一档仍能覆盖 \(Int(demand.width)) 像素宽的，就是它）")
        if let held = settledTier, held != noHysteresis {
            // 字节数按**档位算**，不按缓存里的实际条目读：不做迟滞的那一档根本没被
            // 解出来过，读条目会得到 0，写成"0.0 MB"会被当成"省下了全部内存"。
            print("     迟滞的内存代价       全程可见那张留在 \(tierName(held))"
                + "（\(megabytes(bytes(of: held)))）而不是 \(tierName(noHysteresis))"
                + "（\(megabytes(bytes(of: noHysteresis)))）；换来的是来回缩放不重解")
        }
        print("     新增解码            \(provider.decodeCount - decodedBefore) 次 · "
            + "\(cacheLine(cache))")
        print("     进程 footprint      \(megabytes(footprintBytes()))"
            + " · 读写之后 \(megabytes(touchedFootprint(cache: cache, assets: assets)))"
            + "（把缓存里的像素逐张读一遍再量）")

        // ③ 回到 200%，再走一遍全部 20 张。**这才是那个问题**：
        // "往返一圈之后，20 张里有几张要重解"——只回到第一张的话，
        // 量到的是"第一张在不在缓存里"，说明不了另外 19 张。
        cache.resetStatistics()
        let decodedBeforeReturn = provider.decodeCount
        await walkAll(zoom: 2)
        let reDecoded = provider.decodeCount - decodedBeforeReturn
        print("")
        print("  ③ 回到 200% 再走遍 20 张")
        print("     重新解码            \(reDecoded) 次 / 20   "
            + (reDecoded == 0
               ? "（20 张全尺寸都还在缓存里）"
               : "（缓存装不下 20 张全尺寸，被淘汰的那几张要重解——这就是预算的代价）"))
        print("     缓存                \(cacheLine(cache))")
        print("     账面历史峰值        \(megabytes(cache.peakTotalBytes))")
        print("     进程 footprint      \(megabytes(footprintBytes()))"
            + " · 读写之后 \(megabytes(touchedFootprint(cache: cache, assets: assets)))")
        print("     往返期间取消        \(provider.cancelledBeforeDecodeCount) 次"
            + "（在解码开始之前被顶掉，这些解码没有发生）")
        if reDecoded > elementCountForThrashNote / 2 {
            print("")
            print("     **这一栏值得单独说**：20 张全尺寸是 \(megabytes(bytesPerFullImage * 20))，"
                + "预算是 \(megabytes(cache.byteBudget))。")
            print("     工作集大于预算时，LRU 加上一路向前的扫描会退化成**反复重解**——"
                + "刚解好的那张，")
            print("     在走到它之前就被后面的挤掉了。所以 ③ 里几乎每一张都要重来一次。")
            print("     这不是实现错误，是「缓存放不下整个工作集」的必然结果；")
            print("     它说明 512 MB 这个预算在「20 张 4K 全尺寸」这个场景下不够，"
                + "属于**待决的参数**，不是可以顺手改掉的 bug。")
        }
    }

    // MARK: - 场景四：内存压力

    /// ⑥ 档位边界上的抖动——迟滞**真正**要解决的那个场景。
    ///
    /// ⑤ 量的是"大幅缩放之后的稳态档位"，那证明不了迟滞的价值：大幅缩放时终点那
    /// 一档本来就没有余量，迟滞只是把降档拖慢几轮，**稳态迟早会落到同一档**。
    /// （第 ⑤ 节里"迟滞生效"停在 1/4 而对照是 1/4 时，就是这个情况。）
    ///
    /// 迟滞真正的用处在需求正好骑在一条档位边界上的时候：手指搭在触控板上轻微
    /// 抖动、或者一次捏合停在临界点，需求就在边界两侧来回跨。没有迟滞的话每跨
    /// 一次就换一次档、发一次请求。
    ///
    /// 边界位置是**算出来的**，不是试出来的：`fitting` 在 k 与 k+1 之间的分界是
    /// `demand = original / 2^(k+1)`。两条臂除 `lod.downgradeHeadroom` 外完全相同
    /// ——同一个场景、同样大小的抖动、同样多的次数、同一个起点档位。
    private static func hysteresisBoundaryScenario() async {
        section("6 档位边界上的抖动（迟滞真正要解决的场景）")

        let assets = SyntheticImageProvider.makeUniform4KAssets(count: 2)
        let grid = makeGrid(
            elementCount: 8,
            columns: 4,
            cell: CGSize(width: 1920, height: 1080),
            spacing: CGSize(width: 240, height: 240),
            assets: assets
        )
        let original = assets[0].pixelSize
        // k=2（1/4）与 k=3（1/8）的分界：需求 = 3840 / 8 = 480 像素宽。
        let boundaryZoom = (original.width / 8) / (grid.frames[0].width * displayScale)
        let steps = 24

        print("  抖动中心        缩放 \(number(Double(boundaryZoom), digits: 4))"
            + "——1/4 与 1/8 的分界（需求 \(Int(grid.frames[0].width * boundaryZoom * displayScale)) 像素宽"
            + " = 原图 \(Int(original.width)) / 8）")
        print("  抖动幅度        ±2% · \(steps) 次，每次都跨过边界")

        /// 一条臂的结果。
        struct Arm {
            var label = ""
            var tierChanges = 0
            var decodes = 0
            var hits = 0
            var misses = 0
            var storedBytes = 0
            var startTier = "取不到"
            var endTier = "取不到"
        }

        func run(headroom: CGFloat, label: String) async -> Arm {
            var configuration = MotionConfiguration.default
            configuration.lod.downgradeHeadroom = headroom
            let cache = ImageCache()
            let provider = SyntheticImageProvider(assets: assets, cache: cache)
            let coordinator = makeCoordinator(
                scene: grid.scene,
                provider: provider,
                viewport: canvasViewportSize,
                configuration: configuration
            )
            // 抖动走的是相机写入——捏合最终也是落到这里（`setZoom` + 相机提交），
            // 所以这条路就是真实缩放走的那条，不是另起一条测试通道。
            func setZoom(_ zoom: CGFloat) {
                var camera = coordinator.camera
                camera.setZoom(zoom)
                camera.center = CGPoint(x: grid.frames[0].midX, y: grid.frames[0].midY)
                coordinator.camera = camera
            }

            // 两条臂从同一个状态出发：停在边界**靠细的那一侧**，让档位先收敛。
            setZoom(boundaryZoom * 1.02)
            _ = await settledTier(coordinator: coordinator, id: grid.ids[0])
            await drain()

            var arm = Arm()
            arm.label = label
            arm.startTier = tierName(coordinator.renderedTier(of: grid.ids[0]))
            let tierBefore = PerformanceProbe.counter("tierChange")
            let decodeBefore = provider.decodeCount
            cache.resetStatistics()

            for step in 0..<steps {
                setZoom(step.isMultiple(of: 2) ? boundaryZoom * 0.98 : boundaryZoom * 1.02)
                await drain(20_000_000)
            }
            _ = await settledTier(coordinator: coordinator, id: grid.ids[0])

            arm.tierChanges = PerformanceProbe.counter("tierChange") - tierBefore
            arm.decodes = provider.decodeCount - decodeBefore
            arm.hits = cache.hitCount
            arm.misses = cache.missCount
            arm.storedBytes = cache.totalBytes
            arm.endTier = tierName(coordinator.renderedTier(of: grid.ids[0]))
            return arm
        }

        let withHysteresis = await run(headroom: 1.414, label: "有迟滞（1.414）")
        let without = await run(headroom: 1, label: "无迟滞（1.0，B1 的行为）")

        func line(_ arm: Arm) {
            print("  \(pad(arm.label, to: 24))"
                + "换档 \(arm.tierChanges) 次 · 解码 \(arm.decodes) 次"
                + " · 命中 \(arm.hits) · 未命中 \(arm.misses)"
                + " · 存量 \(megabytes(arm.storedBytes))"
                + " · 终点 \(arm.startTier) → \(arm.endTier)")
        }
        print("")
        line(withHysteresis)
        line(without)
        print("")
        print("  说明            两条臂的**终点档位相同**，抖动次数与幅度也相同，"
            + "只有 `lod.downgradeHeadroom` 不同。")
        print("                  所以「换档次数」这一栏的差别只可能来自迟滞本身。")
        if without.decodes > 0 {
            print("                  无迟滞那条只解码 \(without.decodes) 次、换档却有 "
                + "\(without.tierChanges) 次：两个档位都还装得下缓存，换档大多落在命中上。")
            print("                  缓存装不下时每一次换档就是一次重解——第 5 节 ③ 记的就是那个代价。")
        } else {
            print("                  两条臂的解码都是 0 次：两个档位都还装得下缓存，"
                + "所以这里量到的差别是**换档与请求次数**，不是解码。")
        }
        print("                  边界抖动**不能**在自检里断言：它要的是一条真实的"
            + "「需求贴着边界来回走」的时间序列，")
        print("                  而 `LODTier.settled` 是纯函数——那条轨迹在自检里是直接喂进去的。")
    }

    private static func memoryPressureScenario() async {
        section("7 内存压力响应")

        let viewport = canvasViewportSize
        let assets = SyntheticImageProvider.makeUniform4KAssets(count: 20)
        let grid = makeGrid(
            elementCount: 20,
            columns: 5,
            cell: CGSize(width: 1920, height: 1080),
            spacing: CGSize(width: 240, height: 240),
            assets: assets
        )
        let cache = ImageCache()
        let provider = SyntheticImageProvider(assets: assets, cache: cache)
        let coordinator = makeCoordinator(scene: grid.scene, provider: provider, viewport: viewport)

        // 先把缓存填起来：没有东西可丢的话，"压力来了会缩"这件事验不出任何东西。
        // 和场景三一样走遍 20 张——只停在第一张的话缓存里只有一张。
        for (index, frame) in grid.frames.enumerated() {
            var next = coordinator.camera
            next.setZoom(2)
            next.center = CGPoint(x: frame.midX, y: frame.midY)
            coordinator.camera = next
            await drain(index == 0 ? 150_000_000 : 60_000_000)
        }

        print("  填满之后      预算 \(megabytes(cache.byteBudget))"
            + " · 账面存量 \(megabytes(cache.totalBytes))"
            + " · footprint \(megabytes(footprintBytes()))"
            + " · 读写之后 \(megabytes(touchedFootprint(cache: cache, assets: assets)))")

        for pressure in [ImageCache.MemoryPressure.warning, .warning, .critical] {
            let decodedBefore = provider.decodeCount
            cache.handle(pressure)
            // **压力之后要让画布重新要一遍像素**：这才是"压力过去之后画布还能不能看"。
            // 直接写 `coordinator.camera = coordinator.camera` 是不行的——
            // `adoptCamera` 开头就是 `guard newCamera != storedCamera`，同值写入会被
            // 整个丢掉，什么都不会发生，那一栏数字将永远是 0。
            var nudge = coordinator.camera
            nudge.center.x += 1
            coordinator.camera = nudge
            await drain()

            let name = pressure == .warning ? "warning" : "critical"
            print("  收到 \(name.padding(toLength: 8, withPad: " ", startingAt: 0))"
                + "预算 \(megabytes(cache.byteBudget))"
                + " · 存量 \(megabytes(cache.totalBytes))"
                + " · 淘汰累计 \(cache.evictionCount)"
                + " · 重新解码 \(provider.decodeCount - decodedBefore) 次"
                + " · footprint \(megabytes(footprintBytes()))"
                + " · 读写之后 \(megabytes(touchedFootprint(cache: cache, assets: assets)))")
        }

        print("  收到的压力序列  \(cache.pressureResponses.count) 次"
            + "（**构造的**，调的是 `ImageCache.handle` 这个产品入口；"
            + "系统真实的内存压力在测试里造不出来）")
        print("  预算收缩是单向的：系统报「压力回到正常」不代表可以长回去，"
            + "恢复靠下次启动（`ImageCache.handle` 的说明）")
    }

    // MARK: - 场景五：边界

    private static func printBoundaries() {
        section("8 这些数字不是帧率（口径）")

        print("  1. 本进程**没有窗口**。`CATransaction.commit()` 只是把图层改动写进渲染树；")
        print("     真正的合成、显示链路与垂直同步在 WindowServer 里，这里量不到。")
        print("     所以上面每一个数都是**每帧主线程工作耗时**，不是帧时间，也不是帧率。")
        print("  2. `input` 是外层（一次输入走完输入 → 档位 → 提交），`scan` / `commit*`")
        print("     是它的内层分解——**包含关系，不能相加**。")
        print("  3. 「>8.3ms」的计数**不等于掉帧数**：主线程工作只占一帧的一部分，")
        print("     它吃掉的时间不等于用户看到了一次卡顿。")
        print("  4. 图片解码**不在主线程**（`SyntheticImageProvider.generate` 是")
        print("     `nonisolated async`），所以解码耗时不出现在上面任何一栏里。")
        print("     它的代价体现在「首扫 vs 回扫」的差异上——那是它唯一看得见的地方。")
        print("  5. 异步解码结果落到 `layer.contents` 时**没有显式事务**，那一段提交")
        print("     不在 `commit` 的样本里。")
        print("  6. **进程 footprint 看不见未被触碰的 purgeable 页**，而 CoreGraphics")
        print("     位图上下文的字节正是这么分配的。所以「footprint」那一栏是下界，")
        print("     「读写之后」那一栏才是缓存真正占着的量级。见第 5 节开头。")
        print("  7. 玻璃面板常开，但材质合成在系统侧，这里完全没有它。")
        print("  8. 素材是**合成**的（平面色块 + 细线），真实照片的像素熵高得多。")
        print("     解码耗时与内存都受这一点影响——合成素材偏乐观。")
        print("  9. 帧率、GPU 占用、真机手感需要人工跑一次 Instruments（signpost 已接好：")
        print("     subsystem `com.pin.native.canvas`，category `PointsOfInterest`）。")
        print("     **本报告不代表那一步做过。**")
        print("")
    }

    // MARK: - 脚手架

    private struct Grid {
        let assets: [SyntheticImageProvider.Asset]
        let ids: [CanvasElementID]
        let frames: [CGRect]
        let columns: Int
        let size: CGSize

        var scene: CanvasScene {
            var scene = CanvasScene()
            for (order, id) in ids.enumerated() {
                scene.insert(CanvasElement(
                    id: id,
                    kind: .image(asset: assets[order % assets.count].id),
                    frame: frames[order],
                    order: order
                ))
            }
            return scene
        }
    }

    private static func makeGrid(
        elementCount: Int,
        columns: Int,
        cell: CGSize,
        spacing: CGSize,
        assets: [SyntheticImageProvider.Asset]
    ) -> Grid {
        var ids: [CanvasElementID] = []
        var frames: [CGRect] = []
        for index in 0..<elementCount {
            ids.append(CanvasElementID())
            frames.append(CGRect(
                x: CGFloat(index % columns) * (cell.width + spacing.width),
                y: CGFloat(index / columns) * (cell.height + spacing.height),
                width: cell.width,
                height: cell.height
            ))
        }
        let rows = (elementCount + columns - 1) / columns
        return Grid(
            assets: assets,
            ids: ids,
            frames: frames,
            columns: columns,
            size: CGSize(
                width: CGFloat(columns) * (cell.width + spacing.width) - spacing.width,
                height: CGFloat(rows) * (cell.height + spacing.height) - spacing.height
            )
        )
    }

    /// 走的是产品代码那条路（`CanvasHostView.Coordinator` 挂在真 `NSView` 上），
    /// 不是另写一份等价逻辑——否则测的是测试自己的实现。
    private static func makeCoordinator(
        scene: CanvasScene,
        provider: any ImageProvider,
        viewport: CGSize,
        configuration: MotionConfiguration = .default
    ) -> CanvasHostView.Coordinator {
        let coordinator = CanvasHostView.Coordinator(
            camera: .initial,
            scene: scene,
            selection: [],
            configuration: configuration,
            images: provider,
            commands: CanvasCommandRelay(),
            onSceneChange: { _ in },
            onSelectionChange: { _ in },
            onCameraChange: { _ in }
        )
        let view = CanvasHostNSView(frame: CGRect(origin: .zero, size: viewport))
        coordinator.attach(to: view)
        coordinator.updateViewport(size: viewport, backingScaleFactor: displayScale)
        return coordinator
    }

    /// 让挂起的解码跑完。**不计入任何耗时统计**——它模拟的是两次输入事件之间的
    /// 空闲时间，真实使用里那段时间不属于任何一帧的主线程工作。
    private static func drain(_ nanoseconds: UInt64 = 150_000_000) async {
        for _ in 0..<24 { await Task.yield() }
        try? await Task.sleep(nanoseconds: nanoseconds)
        for _ in 0..<24 { await Task.yield() }
    }

    /// 等一个元素的档位收敛，并记下走过的档位序列。
    ///
    /// **必须推着它走，不能只等。** 迟滞的降档是"每扫一次往下走一级"，而扫描只由
    /// 两件事触发：相机写入、一次解码落地。只 `drain` 的话一轮能走几级取决于当时
    /// 排到了几次解码落地——第一版就是这么写的，同一台机器上给出过 1/2 和 1/4
    /// 两个不同的"收敛值"，**两个看起来都很正常**。
    ///
    /// 所以这里每轮推一下相机（1 个世界单位）：小到不影响档位判定，大到能过
    /// `adoptCamera` 的相等判断，于是每轮**确定地**产生一次扫描。
    ///
    /// 位移取 1 而不是 0：`adoptCamera` 有 `newCamera != storedCamera` 的守卫，
    /// 写回同一个相机是空操作，那样一轮都不会走。
    private static func settledTier(
        coordinator: CanvasHostView.Coordinator,
        id: CanvasElementID,
        maximumRounds: Int = 8
    ) async -> (tier: LODTier?, trajectory: [String], converged: Bool) {
        var trajectory: [String] = []
        var last = coordinator.renderedTier(of: id)
        trajectory.append(tierName(last))
        // 连续两轮不变才算停住。只比一轮的话，一次还没落地的解码就会被
        // 当成"已经收敛"——这正是第一版的错。
        var stable = 0
        for _ in 1...maximumRounds {
            var camera = coordinator.camera
            camera.center.x += 1
            coordinator.camera = camera
            await drain(20_000_000)
            let now = coordinator.renderedTier(of: id)
            if now == last {
                stable += 1
                if stable >= 2 { return (now, trajectory, true) }
            } else {
                stable = 0
                last = now
                trajectory.append(tierName(now))
            }
        }
        return (last, trajectory, false)
    }

    /// 一段平移。相机先摆到起点、等它安定，**然后才重置埋点**——
    /// 否则起点那一次进视口的开销会混进"每帧"的样本里。
    private static func sweep(
        coordinator: CanvasHostView.Coordinator,
        start: CGPoint,
        delta: CGSize,
        frames: Int,
        cache: ImageCache,
        provider: SyntheticImageProvider,
        clearCacheFirst: Bool = false
    ) async -> SweepResult {
        var camera = coordinator.camera
        camera.center = start
        coordinator.camera = camera
        await drain()

        // 首扫要**真的从空缓存出发**。不清的话，起点那几帧已经把沿途会用到的
        // 档位解好了，"首扫"量到的就只是命中——那一栏会显示"解码 0 次"，
        // 看起来像"解码被优化掉了"，实际上是被前面的准备工作吃掉了。
        if clearCacheFirst { cache.removeAll() }

        PerformanceProbe.reset()
        cache.resetStatistics()
        let decodeBefore = provider.decodeCount
        let cancelBefore = provider.cancelledBeforeDecodeCount

        let center = CGPoint(x: coordinator.camera.viewportSize.width / 2,
                             y: coordinator.camera.viewportSize.height / 2)
        var result = SweepResult()
        result.frames = frames
        for _ in 0..<frames {
            let world = coordinator.camera.viewToWorld(center)
            PerformanceProbe.measure("input") {
                coordinator.handleScroll(CanvasScrollInput(
                    viewPoint: center,
                    worldPoint: world,
                    delta: delta,
                    isPrecise: true,
                    phase: .changed,
                    momentumPhase: .none,
                    modifiers: .none
                ))
            }
            // 每帧让出一次主 actor：真实使用里两次事件之间 RunLoop 是空的，
            // 挂起的解码就在那段时间里落地。不让出的话测的是"一口气灌 400 个事件"，
            // 那是一个真实存在但不同的场景。
            await Task.yield()
            result.materializedPeak = max(result.materializedPeak,
                                         coordinator.materializedElementCount)
            result.footprintPeak = max(result.footprintPeak, footprintBytes())
        }

        result.input = PerformanceProbe.samples("input")
        result.scan = PerformanceProbe.samples("scan")
        result.cameraCommit = PerformanceProbe.samples("commit.camera")
        result.sceneCommit = PerformanceProbe.samples("commit")
        result.decodeDelta = provider.decodeCount - decodeBefore
        result.cancelDelta = provider.cancelledBeforeDecodeCount - cancelBefore
        result.hits = cache.hitCount
        result.misses = cache.missCount
        result.evictions = cache.evictionCount
        result.storedBytes = cache.totalBytes
        return result
    }

    private static func report(sweep result: SweepResult, title: String) {
        print("")
        print("  \(title)")
        print("     解码           \(result.decodeDelta) 次"
            + " · 取消 \(result.cancelDelta) 次（解码开始前被顶掉，这些解码没有发生）")
        print("     缓存           命中 \(result.hits) · 未命中 \(result.misses)"
            + " · 淘汰 \(result.evictions) · 存量 \(megabytes(result.storedBytes))")
        print("     每帧主线程工作 \(distribution(result.input))")
        print("     卡顿计数       \(hitches(result.input))")
        print("     其中 扫描      \(distribution(result.scan))")
        print("     其中 相机提交  \(distribution(result.cameraCommit))")
        print("     其中 场景提交  \(distribution(result.sceneCommit))")
        print("     建层峰值       \(result.materializedPeak) 个图层")
        print("     进程 footprint 峰值 \(megabytes(result.footprintPeak))"
            + "（下界：不含 purgeable 页，见第 8 节第 6 条）")
        print("     档位变更次数   \(PerformanceProbe.counter("tierChange"))"
            + " · 发出请求 \(PerformanceProbe.counter("imageRequest")) 次"
            + " · 建层 \(PerformanceProbe.counter("materialize")) 次"
            + " · 丢层 \(PerformanceProbe.counter("dematerialize")) 次")
    }

    // MARK: - 进程内存

    /// 进程的 physical footprint。
    ///
    /// 用 `TASK_VM_INFO.phys_footprint` 而不是 `mach_task_basic_info.resident_size`：
    /// 前者是活动监视器"内存"那一列的口径，后者不含压缩页。两者在本机实测里
    /// 差别不大，但口径要说清楚——报告里的数字必须能对上别处看到的数字。
    private static func footprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// 把缓存里现有的像素**逐张读一遍**再量 footprint。
    ///
    /// ## 为什么必须多这一步（这是本轮实测发现的一个坑）
    ///
    /// macOS 的 `phys_footprint` 与 `resident_size` **不计未被触碰的 purgeable
    /// 页**，而 CoreGraphics 位图上下文的字节正是这么分配的。同机实测：
    ///
    /// ```text
    /// 刚造出 16 张 4K（账面 506 MB）→ footprint 2 MB
    /// 逐张 draw 一次之后            → footprint 509 MB
    /// ```
    ///
    /// 也就是说，**"进程才占 36 MB，所以图片缓存没占内存"这句话是错的**——
    /// 是量具看不见它。不把这件事写清楚，这份报告里最该被相信的那一栏
    /// （内存）恰恰是最不可信的。
    ///
    /// 读的方式是画进一张 64×64 的 scratch 位图：真实读取像素，但不留下一张
    /// 会改变结论的副本。档位 0…5 全试一遍，缓存里有多少就碰到多少。
    private static func touchedFootprint(
        cache: ImageCache,
        assets: [SyntheticImageProvider.Asset]
    ) -> Int {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let scratch = CGContext(
                  data: nil, width: 64, height: 64,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return footprintBytes() }

        let target = CGRect(x: 0, y: 0, width: 64, height: 64)
        for asset in assets {
            for level in 0...LODTier.maximumLevel {
                if let image = cache.peek(for: asset.id, tier: LODTier(level: level)) {
                    scratch.draw(image, in: target)
                }
            }
        }
        return footprintBytes()
    }
}
