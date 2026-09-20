import Foundation

// **这个文件刻意不 import AppKit。** 它和 `CanvasInputEvent.swift` 一起构成输入层
// 与 AppKit 的分界线：只要这里的 import 还是 Foundation，任何人往协议或值对象里
// 塞 `NSEvent` 都会编译不过。写在注释里的约定会被绕过，编译错误不会。

/// 输入适配器读写画布状态的通道。
///
/// ## 这是给 Codex 的冻结接缝（路线图 §4 规则 2/3）
///
/// 适配器不持有相机、场景或选择，只通过这个协议读写——宿主视图始终是这些状态的
/// 唯一持有者，避免"两个对象各存一份"的经典错位。
///
/// ## 通道为什么这么宽
///
/// 第一版只暴露了相机、视口、动效配置、坐标换算和重绘。那组通道足以实现平移缩放，
/// 但**不足以实现路线图归给 Codex 的选择、框选、多选、元素拖拽和快捷键**：
/// 没有场景查询就没法判断点中了谁，没有命令通道就没法移动元素，没有覆盖层通道
/// 就画不出选择框。第一版的结果是"要么改 CC 所有的文件，要么做不了"——
/// 那等于没有接缝。
///
/// 现在补齐四组：查询（`scene` / `hitTest` / `elements(intersecting:)`）、
/// 命令（`perform(_:)`）、覆盖层（`overlay`）、选择（`selection`），
/// 外加撤销管理器。
///
/// **本协议不依赖 `NSEvent`。** 宿主在边界处就把 AppKit 事件翻译成
/// `CanvasInputEvent.swift` 里的值对象，控制器只消费值对象——这样交互逻辑
/// 可以在测试里构造输入直接断言，不必真的动一次鼠标。
@MainActor
protocol CanvasContext: AnyObject {

    // MARK: - 相机

    var camera: CanvasCamera { get set }
    /// 视口尺寸，视图点。
    var viewportSize: CGSize { get }
    var motionConfiguration: MotionConfiguration { get }

    // MARK: - 场景查询
    //
    // 只读。改场景一律走 `perform(_:)`。

    var scene: CanvasScene { get }
    func element(_ id: CanvasElementID) -> CanvasElement?
    /// 命中世界坐标下最靠上的元素。空白处返回 `nil`。
    func hitTest(worldPoint: CGPoint) -> CanvasElementID?
    /// 框选：与世界矩形相交的元素。
    func elements(intersecting worldRect: CGRect) -> [CanvasElementID]
    /// 元素外框的并集，供「定位内容」使用。空场景为 `.null`。
    var contentBounds: CGRect { get }

    // MARK: - 场景命令

    /// 执行一次场景改动。宿主负责把它同步到 SwiftUI 与渲染器。
    func perform(_ command: CanvasSceneCommand)

    // MARK: - 选择

    /// 当前选中的元素。选择属于输入层，但**存放**在宿主里：
    /// 覆盖层、工具栏可用状态、inspector 都要读它，放在控制器内部会多出一份要同步的副本。
    var selection: Set<CanvasElementID> { get set }

    // MARK: - 覆盖层

    /// 屏幕空间覆盖层（选择框、手柄、对齐辅助线）。
    ///
    /// 位置用世界坐标给，尺寸由渲染器按视图点解释（路线图 §2.3、§3.2）——
    /// 这样"手柄看起来多大"只有一处定义，不会随缩放变粗变细。
    var overlay: CanvasOverlay { get set }

    // MARK: - 撤销

    /// 窗口的撤销管理器。宿主把它接进来，输入层按 macOS 惯例登记逆操作。
    ///
    /// **不要在每次拖拽增量里登记**：一次拖动会产生上百条记录，撤销要按上百次。
    /// 惯用做法是按下时记下原始值，在操作**结束时**登记一次逆操作。
    /// 撤销的粒度与合并策略属于 `SelectionController`，本协议只提供通道。
    var undoManager: UndoManager? { get }

    // MARK: - 重绘与指针

    /// 请求宿主重绘背景（网格等非图层内容）。图层内容由渲染器自己负责。
    func requestRedraw()

    /// 请求切换鼠标指针。
    ///
    /// 输入层决定"该显示哪个"（手柄上是十字、按住空格是张开的手），
    /// 宿主负责把 `CanvasCursor` 翻成 `NSCursor` 并真的设上去——
    /// 输入层不 import AppKit，这条边界和事件翻译是同一条。
    func setCursor(_ cursor: CanvasCursor)
}

/// 画布输入适配器：宿主把翻译好的输入值对象交给他。
///
/// ## 这是给 Codex 替换的接缝
///
/// 路线图 §4 规则 3：CC 的首个 Demo 允许临时最小输入适配器，Codex 接管后替换，
/// **禁止维护两套同时生效的事件逻辑**。所以宿主视图只认这个协议，不认识任何
/// 具体实现——Codex 写 `Canvas/InputController.swift` 实现本协议后，在
/// `CanvasHostView.makeCoordinator` 一处替换即可，**不必改宿主视图**。
///
/// 如果需要的输入事件不在下面这组方法里（例如数位板压感），
/// 按 §4 规则 4 先提接口提案——宿主的事件转发列表要一起改，那属于 CC 的文件。
///
/// ## 路线图 §2.5 的输入约定（实现方必须遵守）
///
/// - 触控板滚动消费系统 `momentumPhase`，**不再叠加第二套衰减**
/// - 鼠标拖动画布不自动拥有系统滚动惯性，本期松手即停
/// - 捏合与拖拽直接跟手；按钮缩放、定位内容才使用缓动
/// - 输入统一在一处处理，避免 `NSScrollView` 与自定义逻辑重复应用位移
/// - 直接操控必须能打断正在播放的程序化动画
@MainActor
protocol CanvasInputAdapter: AnyObject {

    // MARK: 指针

    /// 左键按下。空白处用于拖动画布；元素上的按下属于选择逻辑。
    func pointerDown(_ input: CanvasPointerInput, context: CanvasContext)
    func pointerDragged(_ input: CanvasPointerInput, context: CanvasContext)
    func pointerUp(_ input: CanvasPointerInput, context: CanvasContext)

    /// 未按键的指针移动。
    func pointerMoved(_ input: CanvasPointerInput, context: CanvasContext)

    /// 右键（或 control + 左键）按下。上下文菜单的触发点。
    func secondaryPointerDown(_ input: CanvasPointerInput, context: CanvasContext)

    // MARK: 滚动与捏合

    /// 滚轮 / 触控板滚动。带系统惯性的事件也会交到这里。
    func scrollWheel(_ input: CanvasScrollInput, context: CanvasContext)

    /// 触控板捏合缩放。
    func magnify(_ input: CanvasMagnifyInput, context: CanvasContext)

    // MARK: 键盘

    /// 键盘按下。返回 `true` 表示已消费，宿主不再向上传递。
    func keyDown(_ input: CanvasKeyInput, context: CanvasContext) -> Bool

    /// 键盘松开。
    ///
    /// 存在的唯一理由是**空格平移**：空格是一个「按住期间生效」的模式，
    /// 没有松开事件就退不出来——用户按一下空格，从此左键永远在平移，
    /// 而且看不出为什么。`flagsChanged` 顶不上：空格不是修饰键。
    func keyUp(_ input: CanvasKeyInput, context: CanvasContext)

    /// 仅修饰键按下 / 松开（没有伴随字符键）。
    func flagsChanged(_ modifiers: CanvasModifiers, context: CanvasContext)

    /// 选择被**外部**改掉了（SwiftUI 侧推下来的：点素材面板、换画布）。
    ///
    /// 覆盖层由输入层提交，所以外部改完选择必须让输入层重算一次，
    /// 否则表现是"选中了但画布上没有任何框"。输入层在这里只重算覆盖层，
    /// 不反过来写 `selection`——那只会在 `updateNSView` 里制造回环。
    func selectionDidChange(context: CanvasContext)

    // MARK: 程序化定位（工具栏与菜单）
    //
    // 这三条必须由适配器实现而不是让工具栏直接改相机：按钮缩放和手势要走
    // 同一条路径——同样的锚点规则、同样的缓动、同样可被直接输入打断。

    /// 以视口中心为锚点缩放到指定倍率。
    func zoomTo(_ zoom: CGFloat, context: CanvasContext)

    /// 按倍数步进缩放。
    func zoomStep(_ factor: CGFloat, context: CanvasContext)

    /// 「定位内容」：把给定世界矩形装进视口。
    func focus(on worldRect: CGRect, context: CanvasContext)
}
