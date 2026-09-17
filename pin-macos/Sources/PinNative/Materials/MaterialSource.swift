import Foundation

/// 素材源的稳定标识。
///
/// ## 为什么是字符串而不是 enum
///
/// 第一版是 `enum MaterialSource: String, CaseIterable`。新增一个来源要改
/// **4 处 switch**（标题、图标、空状态标题、空状态说明），分散在 `SourceRail.swift`
/// 和 `MaterialPanel.swift` 两个文件里；而且改的是 `enum` 本身，等于每个来源都在
/// 改所有来源共享的类型定义。
///
/// 现在来源是**数据**（`MaterialSourceCatalog` 里的一条），标识只是一个字符串。
/// 加来源不再触碰任何类型定义，也不会让别的来源的代码重新编译出问题。
///
/// 用包装类型而不是裸 `String`：`MaterialSourceID("screenshot")` 写错字编译器不会拦，
/// 但至少它和别的字符串参数不会互相传错，将来要加校验也只有一个地方。
struct MaterialSourceID: Hashable, Sendable, Codable {
    let raw: String
    init(_ raw: String) { self.raw = raw }
}

/// 一个素材源的描述：界面需要的全部静态信息，加上内容从哪来。
///
/// 这是来源与界面之间**唯一**的契约。`SourceRail` 和 `MaterialPanel` 都只读它，
/// 不认识"截图""花瓣""字体"里的任何一个。
struct MaterialSource: Identifiable {
    let id: MaterialSourceID

    /// 来源栏 tooltip 与面板标题。
    let title: String

    /// 来源栏图标。
    ///
    /// **字体用的是 `a.square`，不是 `textformat`。** `textformat` 系列是
    /// SF Symbols 的本地化变体，在中文系统下整族都变成汉字：`textformat` →「格式」、
    /// `textformat.size` →「大小」、`textformat.abc` →「甲乙丙」，
    /// 与「字体」这个来源名对不上（离屏渲染逐一确认过）。
    /// `.environment(\.locale, Locale(identifier: "en_US"))` 能把它们强制回拉丁字形，
    /// 但那是靠环境值传播生效的，哪天不传播了就悄悄退回汉字。
    /// `a.square` 是拉丁字母 A 加方框，**结构上不可能被本地化**——
    /// 「不会出错」比「现在没错」值钱。
    let systemImage: String

    /// 内容为空时的两行文案。
    ///
    /// 放在这里而不是面板的 `switch` 里：它是**这个来源**的属性，不是面板的属性。
    /// 第一版把它写在面板里，结果"加一个来源"必然要打开面板文件。
    let emptyTitle: String
    /// 说明文字控制在能排满一行、又不至于只剩一两个字换行的长度。
    /// 面板最小可拖到 200pt，所以更短的句子在窄面板下也更稳。
    let emptyMessage: String

    /// 内容区渲染成什么形态。默认条目列表。
    var surface: Surface = .collection

    /// 内容提供者。批次 C 之前的来源都用 `PlaceholderMaterialProvider`。
    let provider: any MaterialProvider

    /// 内容区的形态。
    ///
    /// 为什么要有这个而不是让面板一律渲染列表：路线图里花瓣的形态是
    /// **「在 Pin 里浏览花瓣，采集的图片会进到这里」**——它需要的是一个内嵌浏览面
    /// 加一个结果列表，不是列表本身。这就是"内容形态确实是新的"那种情况，
    /// 藏不掉，也不该假装能藏掉。
    ///
    /// 所以这里的态度是：**内容形态和已有的一样的来源**（又一处本地图片目录、
    /// 又一个远程图片流）只加 catalog 一条数据；**形态是新的**来源加一个 case
    /// 和一个视图。加了 case 之后 `MaterialPanel` 会编译不过，直到新形态被实现——
    /// 这正是想要的：遗漏是编译错误，不是运行时空面板。
    enum Surface: Sendable {
        /// 条目列表（截图、字体、花瓣的采集结果）。
        case collection
        // 花瓣的内嵌浏览将在这里加 `case browser`（路线图 §6：网页悬停采集另分阶段）。
    }
}

/// 当前注册的素材源。
///
/// ## 新增一个来源，改这一个地方
///
/// 在 `make(environment:)` 里加一条 `MaterialSource`。不需要动 `SourceRail`、
/// `MaterialPanel`、`WorkspaceView` 或任何类型定义——它们全部由这份目录驱动。
///
/// ## 顺序即显示顺序
///
/// 来源栏按返回数组的顺序从上往下排。与 Pin Web 的来源栏保持一致：字体在 P0.3.2
/// 取代了站酷。
///
/// ## 为什么是函数而不是 `static let`
///
/// 素材读取要用到数据目录（`Pin/dev-cc` / `Pin/dev-codex` / `Pin`，按 profile 不同），
/// 所以目录必须能拿到 `AppEnvironment`。写成全局常量的话，批次 C 的真实提供者
/// 只能自己再去解析一次环境——那就有了第二处真源，而两处迟早会不一致。
///
/// 副作用是好的：每个启动各自持有一份提供者实例，两个 profile 同时跑也不会
/// 共享内容状态。
@MainActor
enum MaterialSourceCatalog {

    static let screenshots = MaterialSourceID("screenshots")
    static let huaban = MaterialSourceID("huaban")
    static let fonts = MaterialSourceID("fonts")

    /// 建出本轮注册的来源。
    ///
    /// - Parameter environment: 数据目录的来源。批次 C 在这里把它交给真实提供者，
    ///   例如 `ScreenshotMaterialProvider(directory: environment.assetsDirectory)`。
    ///   现在还没有提供者用它，但**参数必须现在就在**——接口晚一步到位，
    ///   第一批实现就会绕开它。
    ///
    /// - Returns: 至少一条。调用方（`WorkspaceModel`）依赖这一点来选定默认来源。
    static func make(environment: AppEnvironment) -> [MaterialSource] {
        [
            MaterialSource(
                id: screenshots,
                title: "截图",
                systemImage: "photo.on.rectangle.angled",
                emptyTitle: "还没有截图",
                emptyMessage: "截图会出现在这里，可拖到画布排版。",
                provider: PlaceholderMaterialProvider(environment: environment)
            ),
            MaterialSource(
                id: huaban,
                title: "花瓣",
                systemImage: "square.grid.2x2",
                emptyTitle: "还没有采集",
                emptyMessage: "在 Pin 里浏览花瓣，采集的图片会进到这里。",
                provider: PlaceholderMaterialProvider(environment: environment)
            ),
            MaterialSource(
                id: fonts,
                title: "字体",
                systemImage: "a.square",
                emptyTitle: "还没有字体",
                emptyMessage: "上传字体文件后，可拖到画布做艺术字。",
                provider: PlaceholderMaterialProvider(environment: environment)
            ),
        ]
    }
}
