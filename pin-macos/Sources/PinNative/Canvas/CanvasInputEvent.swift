import CoreGraphics
import Foundation

// 输入值对象：把 AppKit 事件翻译成可构造、可比较、可断言的纯数据。
//
// ## 为什么不让适配器直接收 NSEvent
//
// `NSEvent` 没法在测试里可靠地合成（位置需要真实窗口，修饰键需要真实键盘状态），
// 于是输入层一旦直接吃 `NSEvent`，选择、框选、拖拽这些逻辑就只能靠手动点击验证。
// 输入控制器是批次 B 里最需要回归测试的一块，所以事件在宿主边界就被拆成值对象：
// 宿主负责 `NSEvent → 值对象`（唯一依赖 AppKit 的一步），控制器只消费值对象。
//
// **本文件刻意不 import AppKit。** 翻译代码在 `CanvasHostView.swift` 里，
// 这样"控制器可以脱离 AppKit 测试"这件事是被文件边界保证的，而不是靠自觉。

/// 修饰键。
///
/// 不用 `NSEvent.ModifierFlags`：那是 AppKit 的 OptionSet，`rawValue` 的位分配
/// 是它的实现细节，且构造它需要 AppKit。
struct CanvasModifiers: OptionSet, Sendable, Hashable {
    let rawValue: UInt8

    static let shift = CanvasModifiers(rawValue: 1 << 0)
    static let command = CanvasModifiers(rawValue: 1 << 1)
    static let option = CanvasModifiers(rawValue: 1 << 2)
    static let control = CanvasModifiers(rawValue: 1 << 3)

    static let none: CanvasModifiers = []

    init(rawValue: UInt8) { self.rawValue = rawValue }
}

/// 鼠标按键。
enum CanvasPointerButton: Sendable, Hashable {
    case left
    case right
    /// 中键等其它按键。
    case other
}

/// 滚动 / 捏合的阶段。
///
/// 系统在手指离开触控板后仍会继续投递一串滚动事件，`momentumPhase` 非空即为惯性段。
/// 路线图 §2.5 要求**直接消费系统惯性、不再叠加第二套衰减**——这个字段就是判据，
/// 没有它就只能靠时间戳猜，而猜错的表现是松手后画面"滑两下"。
struct CanvasScrollPhase: OptionSet, Sendable, Hashable {
    let rawValue: UInt8

    static let began = CanvasScrollPhase(rawValue: 1 << 0)
    static let changed = CanvasScrollPhase(rawValue: 1 << 1)
    static let ended = CanvasScrollPhase(rawValue: 1 << 2)
    static let cancelled = CanvasScrollPhase(rawValue: 1 << 3)
    static let mayBegin = CanvasScrollPhase(rawValue: 1 << 4)
    /// 手指停在触控板上但未移动。
    static let stationary = CanvasScrollPhase(rawValue: 1 << 5)

    static let none: CanvasScrollPhase = []

    init(rawValue: UInt8) { self.rawValue = rawValue }

    var isMomentum: Bool { !isEmpty }
}

/// 指针事件（按下 / 拖动 / 抬起 / 悬停 / 右键）。
///
/// 位置同时给**视图点**和**世界点**：判断"点中哪个元素"要用世界坐标，
/// 判断"离屏幕边缘多近"要用视图坐标，让每个消费方各自换算迟早会漏一处。
struct CanvasPointerInput: Sendable, Hashable {
    var viewPoint: CGPoint
    var worldPoint: CGPoint
    var modifiers: CanvasModifiers
    /// 连击次数。1 为单击，2 为双击。
    var clickCount: Int
    var button: CanvasPointerButton
    var timestamp: TimeInterval
}

/// 滚轮 / 触控板滚动。
struct CanvasScrollInput: Sendable, Hashable {
    var viewPoint: CGPoint
    var worldPoint: CGPoint
    /// 滚动增量，**原样来自 AppKit，未归一化**：触控板给的是视图点，
    /// 鼠标滚轮给的是行数，两者粒度差一个量级。
    ///
    /// 之所以不在这里归一化：归一化系数直接决定滚动手感，而当前手感是实机
    /// 确认过的，改它必须连同真实设备一起调。需要分支时看 `isPrecise`。
    var delta: CGSize
    /// 是否来自精确指针设备。触控板为 `true`，鼠标滚轮为 `false`。
    var isPrecise: Bool
    var phase: CanvasScrollPhase
    var momentumPhase: CanvasScrollPhase
    var modifiers: CanvasModifiers

    /// 这一事件是否属于系统惯性段。
    var isMomentum: Bool { momentumPhase.isMomentum }
}

/// 触控板捏合。
struct CanvasMagnifyInput: Sendable, Hashable {
    var viewPoint: CGPoint
    var worldPoint: CGPoint
    /// 原始增量（0.1 表示放大 10%），不做任何插值。
    var magnification: CGFloat
    var phase: CanvasScrollPhase
    var modifiers: CanvasModifiers
}

/// 键盘按下。
struct CanvasKeyInput: Sendable, Hashable {
    /// 已按修饰键处理过的字符。方向键等没有可打印字符的键为空串。
    var characters: String
    /// 虚拟键码。字符随键盘布局变化，键码不随——快捷键判定应当优先用键码。
    var keyCode: UInt16
    var modifiers: CanvasModifiers
    var isARepeat: Bool
}
