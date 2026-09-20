import Foundation

/// 图片加载失败之后的**自动重试节奏**。
///
/// ## 为什么要有退避，而不是"失败就立刻再试一次"
///
/// 失败最常见的原因是**暂时性**的：外置卷还没挂上、文件正被别的进程独占、
/// 内存吃紧导致这次解码没成。这些情况过几百毫秒就好了。但"立刻再试"在本项目
/// 的代码里等于**每帧试一次**——`requestImage` 是每一次相机写入都会走一遍的
/// 那个扫描的一部分，拖一下画布就是几十上百次请求。
///
/// 所以两条一起：**退避**（每次重试前等更久）与**上限**（试满几次就停）。
/// 到顶之后不是无路可走，而是转到手动：元素上留着失败底色，工具栏出现
/// 「重新加载」——自动重试无限跑下去，用户看到的是画布一直在偷偷解同一张
/// 打不开的图，风扇转起来而屏幕上什么都没有。
///
/// ## 为什么是"等 0.5 / 1 / 2 秒"这三个数
///
/// 用户能感知的时间分界大致是：0.2 秒以内算"立刻"，1 秒左右还能算"它自己在
/// 忙"，再久就必须有可见的反馈了。三档正好把"立刻就好"和"确实坏了"分开，
/// 而总时长 3.5 秒之内跑完——不会出现"用户已经放弃、程序还在后台默默重试"。
///
/// 数字集中在这里，改一个地方就能调整节奏；自检注入一份压扁的节奏
/// （毫秒级）来跑，不必真的等 3.5 秒。
struct ImageRetryPolicy: Equatable, Sendable {

    /// 自动重试的**次数上限**。0 表示不自动重试。
    var maximumAutomaticRetries: Int

    /// 第 1、2、3……次重试之前各等多久。次数超过数组长度时沿用最后一档。
    var delays: [TimeInterval]

    static let `default` = ImageRetryPolicy(
        maximumAutomaticRetries: 3,
        delays: [0.5, 1, 2]
    )

    /// 第 `attempt` 次重试（从 1 开始）之前该等多久。
    func delay(beforeAttempt attempt: Int) -> TimeInterval {
        guard !delays.isEmpty else { return 0 }
        return delays[min(max(attempt, 1), delays.count) - 1]
    }

    /// 完全不自动重试。自检用它把"手动重试"这条路径单独隔离出来测——
    /// 自动重试开着的时候，手动那条即使坏了也会被自动的救回来，断言就成了自证。
    static let none = ImageRetryPolicy(maximumAutomaticRetries: 0, delays: [])
}
