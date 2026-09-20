import Foundation

// 素材源的内容接口。
//
// ## 这一层解决的是什么
//
// 第一版的 `MaterialSource` 只是个 enum，界面需要的一切都靠 switch 现算。
// 再加来源就要改 4 处 switch，而且**没有任何地方描述"内容从哪来"**——
// 批次 C 写素材面板时只能在面板里直接调文件读取，之后加花瓣（要内嵌浏览）
// 或字体（要预览排版）就得把面板拆了重写。
//
// 所以这里把来源拆成两半：**描述**（`MaterialSource`，界面要的静态信息）
// 和**提供者**（本文件，内容从哪来）。面板只认这两样，不认识任何具体来源。

/// 素材条目的稳定标识。
struct MaterialItemID: Hashable, Sendable, Codable {
    let raw: UUID
    init(_ raw: UUID = UUID()) { self.raw = raw }
}

/// 素材面板里的一个条目。
///
/// ## 为什么只有一个标题和一个可选缩略图
///
/// 刻意**不带已解码的图片**：面板缩略图和画布元素必须走同一套解码与缓存
/// （路线图 §2.3 的 LOD 与缓存是给整个应用共用的）。在这里放一张 `NSImage`
/// 会让两处各缓存一份，缩放时内存直接翻倍。
///
/// 也刻意**没有为字体预留字段**：字体要显示什么（族名？字重？预览样张的字号
/// 与文字？）现在猜不出来，猜错的字段比没有字段更碍事。字体源落地时在这里加，
/// 面板的条目视图按 `kind` 分支——那是**一处**分支，不是每个来源一处。
struct MaterialItem: Identifiable, Equatable, Sendable {
    let id: MaterialItemID
    let title: String
    /// 缩略图素材。批次 C 之前恒为 `nil`——还没有素材库可以引用。
    let thumbnail: AssetID?
    let kind: Kind

    enum Kind: Equatable, Sendable {
        case image
        /// 字体条目。字体源属于后续阶段（路线图 §6：字体/文字另分阶段）。
        case font
    }
}

/// 素材源当前的内容状态。
///
/// ## 为什么四种状态从第一天就都在
///
/// 因为这个协议的**全部理由**就是"素材要等一下，而且可能失败"：本地目录读取、
/// 花瓣采集、字体枚举三者都是异步且可失败的。
///
/// 如果第一版只写 `.loaded`，批次 C 一定会以"先同步读一下"起步，然后把失败
/// 分支漏掉——而漏掉的表现是「面板一直空着，没有任何提示」，恰恰是最难查的那种。
/// 状态齐全之后，`refresh()` 抛错该往哪写是确定的。
enum MaterialSourceContent: Equatable {
    /// 还没开始拉取。
    case idle
    case loading
    case loaded([MaterialItem])
    /// 失败原因，直接显示给用户。
    case failed(String)

    var items: [MaterialItem] {
        if case .loaded(let items) = self { return items }
        return []
    }
}

/// 素材源的内容提供者。
///
/// ## 这是给批次 C 填的接口
///
/// 实现方负责"内容从哪来、怎么等、失败了怎么办"；面板负责"怎么显示"。
/// 两者之间只有 `content` 和 `refresh()` 两个词。
///
/// ## 实现约定
///
/// - **必须是 `@Observable` 的类**，否则写进 `content` 后面板不会重绘。
///   协议约束不了这一点，只能写在这里；`PlaceholderMaterialProvider` 是参照。
/// - 全部在主 actor 上。素材读取该在后台线程做的部分，由实现方自己
///   `await` 一个非隔离的读取函数，不要把 `content` 搬到别的 actor 去。
/// - `refresh()` **不要抛错**：失败写进 `.failed(原因)`。抛出去的话面板得再
///   接一层 try，而"失败了显示什么"本来就是内容的一部分。
@MainActor
protocol MaterialProvider: AnyObject {
    /// 数据目录等运行环境，由 `MaterialSourceCatalog.make(environment:)` 注入。
    ///
    /// ## 为什么这件事在协议上而不是在各实现里自己解析
    ///
    /// 素材要从磁盘读，而磁盘位置按 profile 不同（`Pin/dev-cc` / `Pin/dev-codex` /
    /// `Pin`）。如果实现方各自调 `AppEnvironment.resolve()`，就有了第二处真源——
    /// 到时候"界面读的是 dev-cc、面板读的是 dev-codex"这种事不会有任何编译错误。
    ///
    /// 放在协议上还有一个作用：**注入是否真的接通了，可以在运行时断言**。
    /// 只把参数写在 `make` 上、没有消费者的话，参数传没传下去是观察不到的，
    /// 而一个"在那儿但没接线"的参数正是这个项目里反复出现的那类问题。
    var environment: AppEnvironment { get }

    var content: MaterialSourceContent { get }

    /// 重新拉取内容。幂等，可以被重复调用（切换来源、点重试都会调）。
    func refresh() async

    /// 条目缩略图。有缩略图的来源（截图）返回经共享 `ImageProvider` 解出的
    /// 像素；没有的返回 `nil`，行视图退回图标占位。
    ///
    /// ## 为什么放在协议上，而不是行视图直接拿 `ImageProvider`
    ///
    /// 面板只认来源与提供者（`MaterialSource` 的说明），缩略图同样是
    /// "内容怎么来"的一部分。更实际的一条：§3.4 的并发闸门只该有一处，
    /// 行视图各写一份的话，闸门就形同虚设。
    func thumbnail(for item: MaterialItem, targetPixelSize: CGSize) async -> ImageRequestResult?
}

extension MaterialProvider {
    /// 默认没有缩略图：占位提供者与还没实现预览的来源（字体）走这条。
    func thumbnail(for item: MaterialItem, targetPixelSize: CGSize) async -> ImageRequestResult? {
        nil
    }
}

/// 批次 A 的占位提供者：内容恒为空。
///
/// 素材读取属于批次 C（路线图 §5）。它存在的意义不是"先凑合一个"，
/// 而是让面板走**真实的状态机**——你现在看到的空状态是 `.loaded([])` 渲染出来的，
/// 不是面板里写死的一句"还没有截图"。批次 C 换成真实现时，面板一行都不用改。
///
/// 它现在也真的持有 `environment`，虽然自己用不上：这样"注入通没通"是可断言的，
/// 而不是靠读代码确认。批次 C 的实现拿到的就是同一个值。
@MainActor
@Observable
final class PlaceholderMaterialProvider: MaterialProvider {
    let environment: AppEnvironment
    private(set) var content: MaterialSourceContent

    init(environment: AppEnvironment, content: MaterialSourceContent = .loaded([])) {
        self.environment = environment
        self.content = content
    }

    func refresh() async {
        // 真实现会在这里读 environment.assetsDirectory / 等 WebView / 枚举字体，
        // 然后写 content。
    }
}
