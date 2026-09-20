import Foundation

/// 动画参数注入点（路线图 §4 规则 2 的接口冻结项之一）。
///
/// ## 文件归属边界
///
/// 完整参数模型与动画逻辑属于 Codex 的 `Canvas/Motion.swift`
/// （路线图 §4、§3.2）。本文件**只声明渲染器与相机在本批次实际消费的字段**，
/// 作为注入通道存在——没有这个通道，渲染器就只能把参数写死，Codex 也无从调整。
///
/// Codex 扩展字段时按 §4 规则 4 走接口提案：先记录提案与影响，再由本文件主责方实现。
/// 组织方式按路线图 §7 已对齐的结论：**按使用场景分组**（相机定位、按钮缩放、
/// 拖拽、吸附、LOD、面板过渡），而不是按物理量分组。
struct MotionConfiguration: Equatable, Sendable {
    /// 是否遵循系统「降低动态效果」设置（路线图 §3.2 要求支持）。
    ///
    /// 为 `true` 时，程序化动画应当直接跳到终态而不是播放。
    /// 直接操控（拖拽、捏合）不受影响——它本来就不过渡。
    var reduceMotion: Bool

    /// 相机程序化定位（按钮缩放、「定位内容」）的时长，单位秒。
    ///
    /// **直接操控不使用这个值**：路线图 §2.5 要求捏合与拖拽直接跟手，
    /// §3.2 要求直接操控无额外追赶缓动。
    var programmaticCameraDuration: TimeInterval

    /// 相机程序化定位的缓动曲线。
    var programmaticCameraCurve: MotionCurve

    /// 视口虚拟化的预加载边距（路线图 §2.3）。
    ///
    /// 渲染器只保留可见区域加上这个边距内的元素图层。
    /// 见 `Viewport.preloadMargin`——它原来平铺在这一层，B2 把它收进按场景
    /// 分组的结构里（路线图 §3.2 的口径）。
    var viewport: Viewport

    /// 分级解码的换档策略（路线图 §2.3「分级解码 LOD」）。
    var lod: LOD

    /// 视口虚拟化。见 `MotionConfiguration.viewport`。
    struct Viewport: Equatable, Sendable {
        /// 视口外的预加载边距，**单位视图点**（不是世界单位、也不是像素）。
        ///
        /// 用视图点的理由是它与缩放无关：不管缩放到多少，屏幕外多留出的那一条
        /// 宽度是稳定的。换成世界单位的话，缩到很小的时候边距会覆盖半个宇宙，
        /// 虚拟化就等于没做。
        ///
        /// 值的取法：它要盖住"一次快速平移在一帧内能走多远"。取小了，快速拖动时
        /// 边角会看到元素还没建出来；取大了，等于白留着看不见的图层。256pt 在
        /// 1280×800 的视口上是四分之一屏宽。
        ///
        /// **这个字段在 B2 之前没有消费者**（B1 时期渲染器不筛元素），
        /// 现在由 `LayerRenderer.refreshVisibleContent()` 读。
        var preloadMargin: CGFloat

        static let `default` = Viewport(preloadMargin: 256)
    }

    /// LOD 换档策略。见 `MotionConfiguration.lod`。
    ///
    /// ## 为什么需要迟滞，以及它为什么只在一侧
    ///
    /// 档位是 2 的幂（`LODTier`），所以"需求刚好落在档位边界上"时，缩放的
    /// 一点点抖动就会让档位来回翻——每次翻都发一次解码请求。这是抖动的来源。
    ///
    /// 迟滞**只能加在往粗的那一侧**：
    ///
    /// - **放大到需求超过当前档** ⇒ 必须立刻换细档。不换就是画面糊，
    ///   而"糊"是这个项目里明确不能忍的状态（§2.3「不显示过期图」同理）。
    /// - **缩小到更粗的一档也够用** ⇒ 可以等一等。等的是"更粗那档到底够不够
    ///   余裕"，代价只是多占一点内存，收益是把边界抖动挡掉。
    ///
    /// 所以阈值只有一个，且方向是明确的：**换细立刻，换粗要余量**。
    struct LOD: Equatable, Sendable {
        /// 降档所需的余量倍数。
        ///
        /// 判据：更粗那一档的像素要覆盖当前需求 **这么多倍** 才允许降。
        ///
        /// - `1.0` = 没有迟滞，等价于"直接用 `LODTier.fitting` 的结果"
        ///   （B1 的行为，也是注入回归时用来回到旧行为的档）。
        /// - `2.0` = 必须余出一整档：降档后画面是 2 倍过采样，缩放的来回抖动
        ///   要在档位边界附近持续一个整档才会触发第三次换档。
        /// - 默认 `√2`：余量半档多一点，是"省内存"与"别抖"之间的折中。
        ///
        /// 迟滞区间内的档位**不会低于需求量**——它只在"本来就够、甚至还富余"
        /// 的档位之间拖时间，永远不会停在糊的那一档上。
        var downgradeHeadroom: CGFloat

        static let `default` = LOD(downgradeHeadroom: 1.414)
    }

    /// 动画是否可以被打断。
    ///
    /// 路线图 §3.2 要求「动画可被新的直接输入打断」。本批次恒为 `true`，
    /// 保留为字段是为了让 Codex 在调参窗口里能对比两种行为。
    var allowsInterruption: Bool

    /// 直接操控的手感参数（路线图 §2.5）。
    ///
    /// ## 为什么单独分一组
    ///
    /// 上面那几个字段是**程序动画**的参数；这一组是**手指直接操控**的参数。
    /// 两类调法不一样：程序动画调的是"看起来舒不舒服"，直接操控调的是
    /// "跟不跟手"——后者只能在真机上试，而且触控板与鼠标的最优值差很远。
    var feel: Feel

    /// 直接操控与手感。见 `MotionConfiguration.feel`。
    ///
    /// ## 这些数字为什么必须在这里，而不是散在调用点
    ///
    /// 第一版每处都是字面量（`1 + delta.height * 0.01`、`frameInterval = 8ms`、
    /// 工具条上的 `1.25`），结果是**手感参数散落在四个文件里**，调一次手感要
    /// 全项目搜索，而且搜索本身不可靠——`0.01` 这样的数字到处都是。
    ///
    /// 收拢之后，后续细化（调参窗口、按设备区分、用户偏好）都是改这一处。
    /// 每个字段都注明了它影响什么、以及**改了会怎样**。
    struct Feel: Equatable, Sendable {

        /// 滚动平移的倍率。触控板与精确指针设备用这个值。
        ///
        /// 1 = 位移与系统给的点数一对一。**不要拿它补偿"感觉慢"**：
        /// 触控板的滚动速度是系统设置里调的，这里叠加倍率会和系统手感打架。
        /// 它存在的意义是给"某些设备上需要偏一点"留一个旋钮。
        var panSpeed: CGFloat

        /// 非精确设备（鼠标滚轮）的**行 → 视图点**换算系数。
        ///
        /// AppKit 对这类设备给的是行数而不是点数（见 `CanvasScrollInput.delta`），
        /// 两者差一个量级。当前是 **1（不换算，与批次 A 行为一致）**：
        /// 本机没有鼠标可实测，凭猜给一个值会把"手感已实机确认"这件事弄脏。
        /// 要接鼠标时改这一个字段。
        var mouseWheelLinesToPoints: CGFloat

        /// 捏合缩放的倍率。1 = 原始增量直接用。
        var magnifySensitivity: CGFloat

        /// ⌘ + 滚动缩放：**每一点滚动增量**对应的缩放比例变化。
        ///
        /// 0.01 表示"滚一格（约 10 点）缩放约 10%"。
        /// 触控板给的点数远大于鼠标的行数，所以这个值只在精确设备上合理；
        /// 非精确设备要另给一个（走 `mouseWheelLinesToPoints` 换算之后再乘）。
        var commandScrollZoomSensitivity: CGFloat

        /// 按钮缩放与菜单 `⌘=` / `⌘-` 的步进比例。
        ///
        /// 从 `CanvasToolbar` 挪过来的：它是手感参数，不是界面布局参数，
        /// 而工具栏里放着它意味着"只有点按钮才能改"。
        var zoomStepFactor: CGFloat

        /// 程序化相机动画的帧间隔，单位秒。
        ///
        /// 8ms ≈ 120Hz，与 ProMotion 的刷新节奏对齐。快于刷新没有意义，
        /// 慢了会在高刷屏上看出台阶。
        var animationFrameInterval: TimeInterval

        static let `default` = Feel(
            panSpeed: 1,
            mouseWheelLinesToPoints: 1,
            magnifySensitivity: 1,
            commandScrollZoomSensitivity: 0.01,
            zoomStepFactor: 1.25,
            animationFrameInterval: 0.008
        )
    }

    static let `default` = MotionConfiguration(
        reduceMotion: false,
        programmaticCameraDuration: 0.28,
        programmaticCameraCurve: .easeOut,
        viewport: .default,
        lod: .default,
        allowsInterruption: true,
        feel: .default
    )

    /// 从系统「降低动态效果」设置与运行参数合成一份配置。
    static func resolved(reduceMotion: Bool) -> MotionConfiguration {
        var configuration = MotionConfiguration.default
        configuration.reduceMotion = reduceMotion
        return configuration
    }
}

enum MotionCurve: String, CaseIterable, Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInOut

    /// 归一化时间 `t`（0…1）对应的进度。纯函数，方便调参窗口直接画曲线。
    func progress(at t: Double) -> Double {
        let t = t.clamped(to: 0...1)
        switch self {
        case .linear: return t
        case .easeIn: return t * t
        case .easeOut: return 1 - (1 - t) * (1 - t)
        case .easeInOut: return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        }
    }

    var displayName: String {
        switch self {
        case .linear: return "线性"
        case .easeIn: return "缓入"
        case .easeOut: return "缓出"
        case .easeInOut: return "缓入缓出"
        }
    }
}
