import Foundation
import Observation

/// 工作台状态。SwiftUI 侧唯一的可变真源。
///
/// ## 画布相关的一切都在 `boards` 里
///
/// 场景、相机、选择都是**每块画布各一份**，不再是这个类型上的三个字段。
/// 为什么：这三样加多画布时都得变成复数，而它们已经同时被工具栏、宿主视图、
/// 快照工具和自检依赖——等到那时再改就是一次波及全部调用点的结构改动。
/// 收进 `BoardStore` 之后，加多画布是加界面和加持久化，不是改结构。
///
/// 下面那三个转发属性是为了让调用点读起来仍然是"当前画布的场景/相机/选择"——
/// 它们没有自己的存储，只是 `boards` 的视图。
@MainActor
@Observable
final class WorkspaceModel {

    struct SVGEditingDocument: Identifiable {
        let asset: AssetID
        var source: String
        let groups: [SVGGroup]
        /// Figma 式钻取的当前位置；空表示根 SVG，非空表示当前 `<g>`。
        var activeGroupID: String?
        var id: AssetID { asset }
    }

    let environment: AppEnvironment

    /// 全部画布与当前画布。本轮只有一块（路线图 §6），但集合是真的。
    let boards: BoardStore

    /// 当前画布的场景。批次 A 不插入任何元素；批次 B/C 的导入会经命令通道改它。
    var scene: CanvasScene { boards.activeScene }

    /// 当前画布的相机。`CanvasHostView` 的直接操控与工具栏按钮都改这一个值。
    var camera: CanvasCamera {
        get { boards.activeCamera }
        set { boards.activeCamera = newValue }
    }

    /// 当前画布选中的元素。选择逻辑属于 Codex 的 `SelectionController`，
    /// 这里只持有结果供覆盖层与工具栏读取。
    var selection: Set<CanvasElementID> { boards.activeSelection }

    /// Toolbar modes are view state, not part of the saved canvas scene.
    var canvasTool: CanvasTool = .select
    var showsCanvasGrid = true
    var svgEditingDocument: SVGEditingDocument?

    var motionConfiguration: MotionConfiguration

    /// 数据目录准备失败的原因。非空时界面必须显示出来。
    ///
    /// 第一版用 `try?` 吞掉了这个错误。空画布阶段看不出问题，但进入导入与保存后
    /// 它的表现是「界面一切正常、数据不落盘」——那时再查要绕很大一圈。
    ///
    /// 从 C1 起它同时装**保存失败**：两者对用户是同一件事（"我的东西没存住"），
    /// 而分成两个字段的话，界面上就得有两处提示，用户还得自己判断哪个更严重。
    private(set) var storageError: String?

    /// 这一次 `storageError` 是不是"暂时打不开"（忙锁、临时 I/O）。
    ///
    /// 界面靠它决定**要不要接着自动试**：暂时打不开值得再试一次，而"库真的坏了"
    /// 或"结构升不上去"再试一百次也是同一个结果，只是在拖着用户等。
    /// 不放进 `storageError` 那段文案里再解析出来：文案是要改的，解析文案
    /// 等于把两件事绑在一起。
    private var storageFailureIsTransient = false
    private var didRestore = false
    private var isRecoveringStorage = false

    /// 库。`prepareStorage()` 之前是 `nil`。
    private(set) var library: LibraryDatabase?

    /// 上一次启动时，原来的库打不开、被改名让路这件事（C2 §4 第 4 条）。
    ///
    /// **非空就必须显示出来**，而且不能自己消失：它说的是"你原来那份数据
    /// 现在在别的地方，界面里这些是新库"。做成几秒后自动消失的提示，
    /// 用户很可能正好没看见——而他要做的判断（去不去把文件捞回来）
    /// 是这一次性的。
    private(set) var quarantine: LibraryQuarantine?

    /// 素材的落盘与读写。导入走它（§3.3）。
    private(set) var assets: AssetStore?

    /// 落库调度器。退出时要靠它刷盘。
    private(set) var writer: SceneWriteScheduler?

    /// 导入协调器。`prepareStorage()` 之前是 `nil`——它要拿 `AssetStore`，
    /// 而那个只有在库打开之后才存在。三条采集通道的唯一入口（§3.3）。
    private(set) var importer: ImportCoordinator?

    /// 素材 ID → 文件位置。**启动时装一次，之后只查内存**——解码路径上不许有
    /// 数据库查询（见 `AssetFileLocator`）。
    let assetLocator: SnapshotAssetLocator

    /// 剪贴板读者（§4 第 2 条）。**注入而不是直接读系统剪贴板**：
    /// 自检绝不能碰用户的真剪贴板——那会把用户正在复制的东西顶掉，
    /// 比不测还糟。生产路径用的是默认值 `PasteboardReader()`。
    private let clipboard: any ClipboardReading

    /// 素材库的迟到接线（§3.4）：来源目录在 init 时就建，那时库还没打开；
    /// `prepareStorage()` 把 store 放进来，截图提供者每次 refresh 都问它。
    let assetLookup = AssetStoreLookup()

    /// 库里现在有多少条素材。素材面板（§3.4）读它。
    private(set) var snapshotAssetCount = 0

    /// 工具栏命令通道。由 `CanvasHostView` 在挂载时填入实现。
    let commands = CanvasCommandRelay()

    /// 像素管线的唯一实例。
    ///
    /// **由模型持有，向下注入渲染器**，理由和 `materialSources` 一样：它是
    /// 一份共享资源，不是渲染器的私人物品。画布元素和素材面板缩略图必须走
    /// 同一个实例，否则同一张图解码两遍，缩放时内存翻倍。
    ///
    /// 批次 C 起是真实现（`FileImageProvider`，§3.2）：像素来自磁盘上的素材
    /// 文件。B1 的合成提供者只还活在自检与演示工具里。
    let images: any ImageProvider

    /// 上面那一个实例的具名类型。导入探针（`ImageFileProbing`）也要它，
    /// 而协议变量身上拿不回具体类型——各建一个的话，"探针读的"和
    /// "画布解码的"就成了两个实现，路径分叉就从这里开始。
    private let fileImageProvider: FileImageProvider

    /// 像素的共享缓存。**单独持有**，因为它不只被提供者用：
    ///
    /// - 内存压力要能找到它（`MemoryPressureMonitor` 直接调 `handle(_:)`）；
    /// - B2 的报告要读它的账面（峰值、命中率、淘汰次数）。
    ///
    /// 留在提供者内部的话，这两件事都得多穿一层协议——而"只有一处知道总共占了
    /// 多少字节"这个前提（见 `ImageCache`）要求它有一个明确的持有者。
    let imageCache: ImageCache

    /// 合成素材目录。B1 阶段它同时是"演示内容的来源"——
    /// 详见 `SyntheticImageProvider.makeAssets(count:)`。
    let syntheticAssets: [SyntheticImageProvider.Asset]

    /// 左侧素材面板是否展开。
    var isMaterialPanelVisible = true

    /// 「花瓣」来源面板里那个网页。
    ///
    /// ## 为什么归模型而不是归视图
    ///
    /// 面板折叠或切走来源时 SwiftUI 会拆掉面板视图；网页归视图所有的话会跟着
    /// 被销毁，再展开就是重新加载、重新登录。归模型所有，视图只是把同一张网页
    /// 挂进挂出（见 `WebBrowserModel`）。
    ///
    /// ## 为什么懒建
    ///
    /// `HeadlessImport` / `SnapshotHarness` 也建 `WorkspaceModel`，而那些进程
    /// 从不开窗口。在 `init` 里就建 `WKWebView` 的话，纯命令行导入也要先付一次
    /// WebKit 的初始化代价，甚至在没有 App 上下文时出问题。
    ///
    /// `@ObservationIgnored`：它在**首次读取时**创建，参与观察的话这次读取
    /// 本身就是一次状态改动，会在视图更新期间触发 SwiftUI 的违规告警。
    @ObservationIgnored private var lazyBrowser: WebBrowserModel?

    var webBrowser: WebBrowserModel {
        if let lazyBrowser { return lazyBrowser }
        let browser = WebBrowserModel()
        lazyBrowser = browser
        return browser
    }

    /// 本轮注册的素材来源。
    ///
    /// **由 `environment` 建出来，不是全局常量**：素材读取要用数据目录，而目录按
    /// profile 不同。视图不再自己去查目录表，只读这一个值——这样"来源列表"
    /// 只有一个真源，批次 C 的真实提供者也有地方拿目录。
    let materialSources: [MaterialSource]

    /// 当前选中的来源。
    var activeSourceID: MaterialSourceID

    /// 当前来源。**非空保证**：`materialSources` 至少一条（见 `make(environment:)`）。
    var activeSource: MaterialSource {
        source(activeSourceID) ?? materialSources[0]
    }

    func source(_ id: MaterialSourceID) -> MaterialSource? {
        materialSources.first { $0.id == id }
    }

    init(
        environment: AppEnvironment = .resolve(),
        boards: BoardStore = BoardStore(),
        syntheticAssetCount: Int = 12,
        imageCache: ImageCache = ImageCache(),
        clipboard: any ClipboardReading = PasteboardReader()
    ) {
        self.environment = environment
        self.boards = boards
        self.motionConfiguration = .default
        self.assetLocator = SnapshotAssetLocator(root: environment.dataDirectory)
        self.clipboard = clipboard
        // 素材表先建出来，再拿它建提供者——提供者不自己生成素材，
        // 这样"画布上有哪些图"和"演示场景往画布上放哪些图"是同一份数据。
        let assets = SyntheticImageProvider.makeAssets(count: syntheticAssetCount)
        self.syntheticAssets = assets
        self.imageCache = imageCache
        let provider = FileImageProvider(locator: assetLocator, cache: imageCache)
        self.fileImageProvider = provider
        self.images = provider
        // 先建列表再选默认来源：`activeSourceID` 不能指向一个不存在的来源。
        // 截图源从这里起是真提供者（§3.4）：素材库经 `assetLookup` 迟到接线，
        // 缩略图与画布共用 `provider` 这一份管线。
        let sources = MaterialSourceCatalog.make(
            environment: environment,
            assets: assetLookup,
            images: provider
        )
        self.materialSources = sources
        self.activeSourceID = sources[0].id
    }

    /// 缩放百分比的显示文本。
    var zoomPercentText: String {
        "\(Int((camera.zoom * 100).rounded()))%"
    }

    /// 窗口尺寸变化后由 `CanvasHostView` 回报。
    func updateViewport(size: CGSize) {
        boards.updateViewport(size: size)
    }

    /// 画布宿主改过场景后回写。宿主是直接操控期间的权威版本，这里只跟着走。
    func applyScene(fromCanvas scene: CanvasScene) {
        boards.applyScene(scene)
    }

    func applySelection(fromCanvas selection: Set<CanvasElementID>) {
        boards.applySelection(selection, for: boards.activeBoardID)
    }

    var canEditSelectedSVG: Bool {
        guard selection.count == 1, let id = selection.first else { return false }
        return canEditSVGElement(id)
    }

    /// SVG 编辑入口必须按**文件内容**判定，不按画布元素的 `image` 类型猜测。
    /// 位图和 SVG 在场景里都复用 `.image`，若只看元素种类，右键 PNG/JPEG 也会
    /// 露出一个点了无反应的「编辑 SVG」。
    func canEditSVGElement(_ elementID: CanvasElementID) -> Bool {
        guard let element = scene.element(elementID), case .image(let asset) = element.kind,
              let url = assetLocator.fileURL(for: asset)
        else { return false }
        return SVGImageSupport.isSVG(url: url)
    }

    func beginEditingSelectedSVG() {
        guard selection.count == 1, let elementID = selection.first
        else { return }
        beginEditingSVGElement(elementID)
    }

    func beginEditingSVGElement(_ elementID: CanvasElementID) {
        guard
              canEditSVGElement(elementID),
              let element = scene.element(elementID), case .image(let asset) = element.kind,
              let url = assetLocator.fileURL(for: asset),
              let data = try? Data(contentsOf: url), let source = String(data: data, encoding: .utf8)
        else { return }
        svgEditingDocument = SVGEditingDocument(
            asset: asset, source: source, groups: SVGStructure.groups(in: source), activeGroupID: nil
        )
    }

    func enterSVGGroup(_ groupID: String) {
        guard var document = svgEditingDocument,
              document.groups.contains(where: { $0.id == groupID }) else { return }
        document.activeGroupID = groupID
        svgEditingDocument = document
    }

    func exitSVGGroup() {
        guard var document = svgEditingDocument, let active = document.activeGroupID else { return }
        document.activeGroupID = document.groups.first(where: { $0.id == active })?.parentID
        svgEditingDocument = document
    }

    func saveSVGEditing(_ document: SVGEditingDocument) async -> String? {
        guard let assets else { return "素材库尚未准备好" }
        do {
            _ = try await assets.replaceSVG(document.asset, with: Data(document.source.utf8), using: fileImageProvider)
            imageCache.invalidateAllTiers(of: document.asset)
            commands.reloadAsset?(document.asset)
            await refreshMaterialSources()
            svgEditingDocument = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 建立数据目录结构**并打开库**。可重试——失败原因会显示在界面上。
    ///
    /// ## 为什么打开库放在这里，而不是 `init`
    ///
    /// `init` 不能抛错（`@State` 的初值不给你接错误的地方），而"打不开库"是
    /// 一件**必须说出来**的事：吞掉它的表现是"界面一切正常、数据不落盘"。
    /// 放在这里，失败就走 `storageError` 那条已经通了的路。
    ///
    /// 迁移在 `open` 里同步跑完。迁移是 DDL，空库上是亚毫秒级的；而它必须在
    /// 任何一次读写之前完成，异步化只会让"第一拍就有人读"变成一个竞态。
    func prepareStorage() {
        // A save retry must reuse the scheduler holding the failed job.
        guard writer == nil else { return }
        do {
            try environment.prepareDirectories()
            // 打不开就改名备份再建空库（C2 §4 第 4 条）。**走这条而不是
            // `LibraryDatabase.open`**：静默建空库的表现是"用户的素材凭空没了"，
            // 而 §5 明确要求不静默覆盖。发生的事经 `quarantine` 报到界面上。
            let recovered = try LibraryRecovery.open(at: environment.dataDirectory)
            let database = recovered.database
            quarantine = recovered.quarantine
            let writer = SceneWriteScheduler(store: SceneStore(database: database))
            // 写失败**必须有人接**：静默失败的形态是"界面一切正常、重启全没了"。
            writer.onError = { [weak self] error in
                self?.storageError = "保存失败：\(error.localizedDescription)"
            }
            self.library = database
            self.writer = writer
            self.assets = AssetStore(database: database, root: environment.dataDirectory)
            // 接线之后 `BoardStore` 里**每一条**改动路径都会落库（见 `LibraryWriting`）。
            boards.library = writer
            // 导入协调器（§3.3）：三条采集通道的唯一入口。探针与画布解码是
            // 同一个 `FileImageProvider` 实例。
            if let assets {
                assetLookup.store = assets
                self.importer = ImportCoordinator(
                    store: assets,
                    prober: fileImageProvider,
                    boards: boards,
                    locator: assetLocator
                )
            }
            storageError = nil
            storageFailureIsTransient = false
        } catch {
            let openError = error as? DatabaseOpenError
            storageFailureIsTransient = openError?.isRetryable ?? false
            let reason = openError?.errorDescription ?? error.localizedDescription
            // 「暂时打不开」与「库坏了」对用户是两件事：前者等一会儿再试就行，
            // 后者要他去看备份。文案必须分开，否则用户会以为素材没了。
            storageError = storageFailureIsTransient
                ? "素材库暂时打不开，请稍后重试（\(reason)）"
                : reason
        }
    }

    /// 启动与界面上的「重试」都走这条：**暂时打不开**就自动再试几次。
    ///
    /// 产品负责人 2026-09-20 定。只有"暂时打不开"值得重试：库真的坏了要走隔离
    /// （改名备份 + 建新库），结构升不上去则要停下来让人看——那两种再试一百次
    /// 也是同一个结果，只会让用户多等。
    ///
    /// 试 3 次、间隔 200 毫秒。SQLite 自己已经为忙锁等了 5 秒
    /// （`configuration.busyMode`），所以这里要救的是"另一个实例正好在退出"
    /// 这类再等一下就好、而那 5 秒又没等到的情形。再长就变成启动卡顿，
    /// 那正是 §2.4 的主线程预算要挡的东西。
    func prepareStorageWithRetry() async {
        for attempt in 1...Self.storageAttempts {
            prepareStorage()
            guard storageFailureIsTransient, attempt < Self.storageAttempts else { return }
            try? await Task.sleep(for: Self.storageRetryDelay)
        }
    }

    /// 打不开库时最多试几次、每次之间等多久。见 `prepareStorageWithRetry`。
    private static let storageAttempts = 3
    private static let storageRetryDelay = Duration.milliseconds(200)

    /// One entry point for startup and the Retry button. Never replaces a writer
    /// that still owns unsaved scene changes.
    func recoverStorage() async {
        guard !isRecoveringStorage else { return }
        isRecoveringStorage = true
        defer { isRecoveringStorage = false }

        if writer == nil { await prepareStorageWithRetry() }
        guard writer != nil else { return }
        if let error = await flushLibrary() {
            storageError = "保存失败：\(error.localizedDescription)"
            return
        }
        if !didRestore {
            await restore()
        } else {
            storageError = nil
        }
    }

    /// 从库里恢复。启动时调一次。
    ///
    /// ## 恢复的是"库里有什么"，恢复不了的一律是这个类型自己给的
    ///
    /// - **相机**回初始视角、**选中**为空（§7 第 6、7 条）——快照里根本没有它们；
    /// - **空库建一块默认画布**：那是 `BoardStore` 的不变量。新画布要立刻落库，
    ///   否则"新建画布的这一刻"与"下一次启动"之间什么都没有，而用户在这中间
    ///   导入的素材会挂在一块重启后不存在的画布上（外键挡得住，但那是报错而不是
    ///   恢复）。
    func restore() async {
        guard let library else { return }
        do {
            let snapshot = try await LibrarySnapshot.load(from: library)
            boards.restore(from: snapshot)
            assetLocator.replace(with: snapshot.assets)
            snapshotAssetCount = snapshot.assets.count
            if snapshot.boards.isEmpty, let writer {
                writer.persist(board: boards.activeBoard, sort: 0)
                if let error = await writer.flushReportingFailure() {
                    storageError = "保存失败：\(error.localizedDescription)"
                    return
                }
            }
            // 面板内容跟着库走（§3.4）：恢复完成之后拉一次，素材列表就是
            // 库里的真实内容。面板自己的 `.task` 也会拉，`refresh()` 幂等。
            await refreshMaterialSources()
            didRestore = true
            storageError = nil
        } catch {
            storageError = "读不了素材库：\(error.localizedDescription)"
        }
    }

    /// 立刻把待写的都写完。退出、切画布、导入之后调。
    @discardableResult
    func flushLibrary() async -> Error? {
        await writer?.flushReportingFailure()
    }

    /// 导入一批文件（§3.3 的对外入口）。§3.6 的工具栏按钮调它；
    /// Finder 拖入与粘贴（§4）以后也汇到这里。
    ///
    /// - Parameters:
    ///   - placingOnCanvas: `false` 只入库不摆画布——素材面板的拖入落点（§4）
    ///     与演示工具用它。
    ///   - origin: 素材来源，进库（`AssetRecord.Origin`）。
    ///   - anchor: 摆上画布时的落点（世界坐标）。拖入给光标位置；`nil` =
    ///     视口中心。
    ///
    /// 素材库没准备好时（`storageError` 非空），每个文件都拿到一个说得出口的
    /// 失败结果——**安静地什么都没发生**是导入最坏的失败形态：用户点了按钮，
    /// 界面没有半点反应。
    @discardableResult
    func importFiles(
        _ urls: [URL],
        origin: AssetRecord.Origin = .fileImport,
        placingOnCanvas: Bool = true,
        anchor: CGPoint? = nil
    ) async -> [URL: ImportCoordinator.FileOutcome] {
        guard didRestore, let importer else {
            let reason = storageError ?? (writer == nil ? "未知原因" : "素材库仍在恢复中")
            let rejected = ImportCoordinator.FileOutcome.rejected(
                .failed("素材库没准备好：\(reason)")
            )
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, rejected) })
        }
        let outcomes = placingOnCanvas
            ? await importer.importFiles(urls, origin: origin, anchor: anchor)
            : await importer.importFilesToLibrary(urls, origin: origin)
        let saveError = await finishImport(imported: outcomes.values.filter(\.isImported).count)
        guard placingOnCanvas, let saveError else { return outcomes }
        return outcomes.mapValues { outcome in
            if case .imported(let record) = outcome {
                return .storedWithoutCanvasSave(record, saveError)
            }
            return outcome
        }
    }

    /// 粘一次剪贴板（§4 第 2 条）。**⌘V 与拖入都走两条通道的同一个入口**：
    /// 读剪贴板是平台动作，读出来之后怎么处理由 `ImportCoordinator` 决定。
    ///
    /// - Parameter anchor: 落点（世界坐标）。拖入给的是光标松开的位置，
    ///   粘贴给 `nil`（粘贴没有"落点"，落在视口中心才符合预期）。
    ///
    /// - Returns: 给提示胶囊的摘要。**剪贴板里没有图片时是 `.nothingToPaste`**，
    ///   不是 `.finished(0, 1, …)`——见那个 case 的注释。
    func paste(anchor: CGPoint? = nil) async -> ImportFeedback {
        await importPayload(clipboard.read(), origin: .paste, anchor: anchor)
    }

    /// 把一份**已经读出来的**载荷走一遍导入（§4 第 1、2 条）。
    ///
    /// ## 为什么要有这个入口，而不是让拖入自己再写一遍
    ///
    /// 「判大小 → 入库 → 摆画布 → 刷盘 → 刷面板」这条链在上面的 `importFiles`
    /// 和 `paste` 里已经各写了一遍。拖入是第三条通道，再抄一遍的话，最容易漏的
    /// 是最后一跳（`finishImport`）——表现是"拖进去了，但面板里看不见，要重启
    /// 才出现"。
    ///
    /// ## 拖入为什么必须**同步**读完剪贴板再进来
    ///
    /// `NSDraggingInfo.draggingPasteboard` 只在这一次拖放会话里有效。把读剪贴板
    /// 推迟到 `Task { }` 里（这条链上是异步的）就等于去读一块已经被拆掉的板子，
    /// 拿到的是空——而失败表现是"拖进去什么都没发生"。所以调用方在
    /// `performDragOperation` 里当场读出 `ClipboardPayload`（`Data` 是值类型，
    /// 带着走是安全的），再交给这里。
    func importPayload(
        _ payload: ClipboardPayload,
        origin: AssetRecord.Origin,
        anchor: CGPoint? = nil
    ) async -> ImportFeedback {
        guard didRestore, let importer else {
            let reason = storageError ?? (writer == nil ? "未知原因" : "素材库仍在恢复中")
            return .finished(
                imported: 0, rejected: 1,
                firstFailure: "素材库没准备好：\(reason)"
            )
        }
        guard case .none = payload else {
            let outcomes = await importer.importClipboard(payload, origin: origin, anchor: anchor)
            let saveError = await finishImport(imported: outcomes.filter(\.isImported).count)
            let reported = outcomes.map { outcome -> ImportCoordinator.FileOutcome in
                guard let saveError, case .imported(let record) = outcome else { return outcome }
                return .storedWithoutCanvasSave(record, saveError)
            }
            return ImportFeedback.summary(of: reported)
        }
        return .nothingToPaste
    }

    /// 一批导入落地之后的共同收尾：面板计数、刷盘、刷新来源列表。
    ///
    /// 三条通道（选择器、拖入、粘贴）都要做这三件事，抄三遍的话，漏掉的那一条
    /// 表现是"导进去了，但面板里看不见，要重启才出现"。
    private func finishImport(imported: Int) async -> String? {
        guard imported > 0 else { return nil }
        snapshotAssetCount += imported
        let failure = await flushLibrary()?.localizedDescription
        // 面板里要立刻看到新素材（§3.4）：不只是计数，条目列表本身跟着库走。
        await refreshMaterialSources()
        return failure
    }

    /// 界面侧遇到"东西没存住"时回报（导出诊断写文件失败等）。
    ///
    /// 和保存失败共用 `storageError`：对用户来说它们是同一件事，
    /// 分成两个字段就得在界面上开两处提示，用户还得自己判断哪个更严重。
    func reportStorageError(_ message: String) {
        storageError = message
    }

    /// 导出这份诊断的正文（C2 §4 第 4 条）。没有隔离过东西时返回 `nil`。
    ///
    /// 界面拿它去存文件。**存文件这一步不在这里**：写文件要有落点（存到哪儿、
    /// 用户改没改文件名），那是界面的事；这里只负责"说什么"。
    func diagnosticsText() async -> String? {
        guard let quarantine else { return nil }
        let current = await LibraryDiagnostics.readCurrentState(at: environment.dataDirectory)
        return LibraryDiagnostics.render(
            directory: environment.dataDirectory,
            quarantine: quarantine,
            current: current,
            appVersion: Self.appVersion,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    /// 诊断里要写的版本号。取自 `Info.plist`——**不在这里另立一个常量**：
    /// 那份 plist 是打包脚本真正读的那个（`AppBundle/`），两处各写一份的话，
    /// 迟早出现"报告里写的版本和关于本机里看到的不是同一个"。
    private static var appVersion: String {
        let info = Bundle.main
        let short = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = info.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case (let short?, let build?): return "\(short)（\(build)）"
        case (let short?, nil): return short
        case (nil, let build?): return "构建 \(build)"
        // `--selftest` 跑的是裸二进制，没有 plist。写"未知"而不是编一个：
        // 这份文本是给人看的，编一个版本号比没有更糟。
        case (nil, nil): return "未知（不是从应用包启动的）"
        }
    }

    /// 素材内容跟着库走：恢复、导入之后拉一次所有来源。`refresh()` 幂等，
    /// 占位来源（花瓣/字体）的 refresh 是空操作，只有截图源真的去读库。
    func refreshMaterialSources() async {
        for source in materialSources {
            await source.provider.refresh()
        }
    }
}
