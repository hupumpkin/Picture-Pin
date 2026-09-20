import CoreGraphics
import Foundation

/// 采集通道的唯一入口（§3.3）。三条通道——文件选择器、Finder 拖入、粘贴——
/// 共用这一处，C1 只接文件选择器（§4 的另外两条以后接进 `importFiles` 即可）。
///
/// ## "一次导入"的语义只存在一份
///
/// 判大小 → 收字节 → 读属性 → 入库 → 插画布，这条流水线写在 `importFiles`
/// 里。三条通道各自的采集动作（选文件、拖文件、读剪贴板）只是**把 URL 交进来**
/// 的方式不同。流水线散在多处的话，最典型的分叉是"这条路忘了拒绝超大文件"，
/// 而那时留给用户的是一张导入成功、却永远显示不出来的图。
///
/// ## 与 `AssetStore.ingest` 的分工
///
/// `ingest` 负责"收字节"（复制 + 哈希 + 读属性 + 入库，任一步失败删半成品）；
/// 本类型负责**它前面的政策**（超限拒绝在复制之前）和**它后面的落画布**
/// （网格摆进视口中心区域）。政策必须在前：`ingest` 的失败清理保证"没有
/// 半成品文件"，但它防不了"整个文件已经复制完了才说不要"——那一步才是
/// 政策检查该出现的位置。
@MainActor
final class ImportCoordinator {

    /// 一个文件的导入结果。字典键是传入的 URL（同一批里重复传同一个文件时，
    /// 结果不能互相顶掉）。
    enum FileOutcome: Equatable {
        /// 已入库、已插画布。
        case imported(AssetRecord)
        /// Original bytes are safe in the material library, but the canvas write failed.
        case storedWithoutCanvasSave(AssetRecord, String)
        /// 被政策拒绝，或中途失败。**两种情况都没有任何半成品**（§5）。
        case rejected(FileRejection)

        var isImported: Bool {
            if case .imported = self { true } else { false }
        }

        /// 给界面的结果文案（§3.6 的导入结果提示读它）。
        var message: String {
            switch self {
            case .imported(let record):
                "已导入：\(record.originalFilename)"
            case .storedWithoutCanvasSave(let record, let reason):
                "\(record.originalFilename) 已存入素材库，但画布未保存：\(reason)"
            case .rejected(let rejection):
                rejection.message
            }
        }
    }

    /// 拒绝/失败的原因。**分得和 `AssetStore.ImportError` 一样细**：
    /// 用户能采取的动作不同，文案就得不同。
    enum FileRejection: Equatable {
        /// §3.9 第 2 条：最长边或总像素超上限。**复制前就判**——
        /// 一个字节都不落盘，所以也不存在"删半成品"这一步。
        case tooLarge
        /// 其余失败：不是能解码的图片 / 读不了 / 存不进去 / 记不进库。
        /// 文案直接取 `AssetStore.ImportError` 的——那一层已经按"用户能做什么"
        /// 分好口径，这里只做搬运，不再翻译一遍。
        case failed(String)

        var message: String {
            switch self {
            case .tooLarge:
                ImportPolicy.tooLargeMessage
            case .failed(let reason):
                reason
            }
        }
    }

    // MARK: - 依赖

    private let store: AssetStore
    private let prober: any ImageFileProbing
    private let boards: BoardStore
    /// 导入之后要把新素材装进去：不装的话，**重启之前**画布上一直显示不出来
    /// （`SnapshotAssetLocator` 的说明里点过名的那类"像缓存问题"的 bug）。
    private let locator: SnapshotAssetLocator
    private let policy: ImportPolicy
    private let grid: GridPlacement
    private let tempWriter: TemporaryImageWriter

    init(
        store: AssetStore,
        prober: any ImageFileProbing,
        boards: BoardStore,
        locator: SnapshotAssetLocator,
        policy: ImportPolicy = ImportPolicy(),
        grid: GridPlacement = GridPlacement(),
        tempWriter: TemporaryImageWriter = TemporaryImageWriter()
    ) {
        self.store = store
        self.prober = prober
        self.boards = boards
        self.locator = locator
        self.policy = policy
        self.grid = grid
        self.tempWriter = tempWriter
    }

    // MARK: - 导入

    /// 导入一批文件，并摆上当前画布（§3.3 第 5 条）。**逐个处理**：一个失败
    /// 不影响其余——用户选了一百张图，其中一张坏了，另外九十九张必须照常进来。
    ///
    /// 落画布的位置按**整批**排网格：`slot` 是文件在批里的位置，`total` 是批
    /// 大小。网格锚点由整批决定，所以边导入边摆放时，先到的文件已经落在它
    /// 最终的格子里，不会随后面的文件到来而挪动。
    ///
    /// - Returns: 每个 URL 的结果。要按传入顺序读结果，用原来的 `urls` 数组
    ///   去索引——Swift Dictionary 不保证迭代顺序（§3.6 的导入摘要第一版
    ///   按字典迭代序取「第一条失败」，自检随进程哈希种子随机红）。
    func importFiles(
        _ urls: [URL],
        origin: AssetRecord.Origin = .fileImport,
        anchor: CGPoint? = nil
    ) async -> [URL: FileOutcome] {
        await run(urls, origin: origin, placing: true, anchor: anchor)
    }

    /// 只入库，不摆画布。Finder 拖入落在素材面板上的那条通道（§4）用它；
    /// 开发工具的演示素材导入也用它——两处要的都是"进库"，摆放是另一件事。
    func importFilesToLibrary(
        _ urls: [URL],
        origin: AssetRecord.Origin = .fileImport
    ) async -> [URL: FileOutcome] {
        await run(urls, origin: origin, placing: false, anchor: nil)
    }

    // MARK: - 粘贴（§4 第 2 条）

    /// 粘一次剪贴板。
    ///
    /// ## 为什么这里返回数组而不是字典
    ///
    /// 另外两条通道的入参是"用户挑的一批 URL"，调用方要按 URL 把结果对回去
    /// （哪个文件失败了、为什么）。粘贴没有这回事：剪贴板里的东西用户刚刚
    /// 才复制过，不需要按 URL 找。而且位图那条路的 URL 是我们自己造的临时
    /// 文件路径，交给界面毫无意义。
    ///
    /// ## 两条形态在这里合流
    ///
    /// 文件 URL 直接进流水线；位图先落成临时 PNG 再进同一条流水线（见
    /// `TemporaryImageWriter` 里为什么不做一条 `ingest(data:)`）。
    /// 合流点在 `run`，所以上限、失败清理、属性读取三件事对三条通道只有一份。
    /// - Parameter origin: 进库时记的来源。**默认 `.paste`，拖入通道传 `.dragIn`**——
    ///   两条通道在这里合流，但"用户是怎么把它弄进来的"不能因此被抹平：
    ///   合流的是流水线，不是来源。
    func importClipboard(
        _ payload: ClipboardPayload,
        origin: AssetRecord.Origin = .paste,
        anchor: CGPoint? = nil
    ) async -> [FileOutcome] {
        switch payload {
        case .none:
            return []
        case .fileURLs(let urls):
            let outcomes = await importFiles(urls, origin: origin, anchor: anchor)
            // 按传入顺序取：字典的迭代序不保证（`importFiles` 的注释里点过名）。
            return urls.compactMap { outcomes[$0] }
        case .image(let data, let name, _):
            let url: URL
            do {
                url = try tempWriter.write(data, named: name)
            } catch {
                return [.rejected(.failed("这张图存不下来：\(error.localizedDescription)"))]
            }
            defer { tempWriter.cleanUp(url) }
            let outcomes = await importFiles([url], origin: origin, anchor: anchor)
            return outcomes.values.map { outcome in
                // 结果文案里的文件名换成用户看得懂的那个：临时路径
                // （`…/pin-paste/<UUID>/粘贴 ….png`）出现在提示里等于什么都没说。
                if case .imported(let record) = outcome {
                    var renamed = record
                    renamed.originalFilename = name
                    return .imported(renamed)
                }
                return outcome
            }
        }
    }

    private func run(
        _ urls: [URL],
        origin: AssetRecord.Origin,
        placing: Bool,
        anchor: CGPoint?
    ) async -> [URL: FileOutcome] {
        var outcomes: [URL: FileOutcome] = [:]
        for (slot, url) in urls.enumerated() {
            outcomes[url] = await importOne(
                url, origin: origin, slot: slot, total: urls.count, placing: placing, anchor: anchor
            )
        }
        return outcomes
    }

    private func importOne(
        _ url: URL,
        origin: AssetRecord.Origin,
        slot: Int,
        total: Int,
        placing: Bool,
        anchor: CGPoint?
    ) async -> FileOutcome {
        // 政策检查放在最前面：先探源文件（只读文件头，不解码像素）。
        // 读不出来的文件不在这里判——交给 `ingest`，它能把"不是图片"和
        // "读不了"分成两种说法，这里提前判只会把两种失败揉成一个。
        if let facts = await prober.probe(url), policy.rejects(facts.pixelSize) {
            return .rejected(.tooLarge)
        }

        do {
            let record = try await store.ingest(from: url, origin: origin, using: prober)
            // 先装定位表再摆画布：摆上画布的下一帧渲染器就会来问这个素材，
            // 定位表里没有它的话，第一帧就是"素材不存在"的红色占位。
            locator.insert(record)
            if placing {
                insertElements([record], slot: slot, total: total, anchor: anchor)
            }
            return .imported(record)
        } catch {
            return .rejected(
                .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            )
        }
    }

    // MARK: - 插画布（§3.3 第 5 条）

    /// 把已入库的素材摆上当前画布：按网格排在视口中心区域。
    ///
    /// 场景改动走 `BoardStore.applyScene`——与画布宿主的直接操控同一条回写
    /// 路径，渲染器经 `CanvasHostView` 的同步收到新元素，库经
    /// `boards.library` 收到差异。命令通道（`CanvasSceneCommand.insert`）是
    /// 画布侧的入口；导入是模型侧的改动，用的是同一场景动作（`CanvasScene.insert`）。
    private func insertElements(
        _ records: [AssetRecord],
        slot: Int,
        total: Int,
        anchor: CGPoint?
    ) {
        let camera = boards.activeCamera
        var scene = boards.activeScene
        var inserted = 0
        for record in records {
            guard let frame = grid.frame(
                at: slot + inserted,
                total: total,
                pixelSize: record.pixelSize,
                camera: camera,
                anchor: anchor
            ) else { continue }
            scene.insert(CanvasElement(
                id: CanvasElementID(),
                kind: .image(asset: record.id),
                frame: frame,
                order: 0
            ))
            inserted += 1
        }
        boards.applyScene(scene)
    }
}

/// 导入落点的网格排布（§3.3 第 5 条：连续导入按网格排在视口中心区域）。
///
/// 纯几何，不碰场景与相机之外的任何状态——排布算错的表现是"图摆在不该摆的
/// 位置"，这类错要靠自检构造相机与批大小直接跑，而不是等画布上摆出来再看。
struct GridPlacement {

    /// 一行最多几列。单张导入时列数收敛为 1，图正好落在视口中心。
    var columns: Int = 3

    /// 单元格是视口（世界坐标）对应边长的几分之几。
    var cellFraction: CGFloat = 0.3

    /// 单元格间距，世界单位。
    var gap: CGFloat = 32

    /// 第 `slot` 张图的落点。网格整体居中于视口中心；最后一个不完整的行靠左
    /// （在网格居中的前提下）。
    ///
    /// 图按**原比例**放进单元格，不拉伸：拉伸会掩盖"外框算错"这类问题
    /// （一张被拉变形的图看起来"填满了"，而正确的比例反而会露出空隙）。
    ///
    /// - Parameter anchor: 网格中心落在哪个世界点上。`nil` = 视口中心。
    ///   拖入与粘贴给的是**光标落点**：用户把图拖到哪儿，它就该出现在哪儿；
    ///   落在视口中心的话，用户会觉得"我明明放在那儿了"。
    ///
    /// - Returns: 世界坐标里的外框。参数不合法（空批、空视口、非正缩放）时 `nil`。
    func frame(
        at slot: Int,
        total: Int,
        pixelSize: CGSize,
        camera: CanvasCamera,
        anchor: CGPoint? = nil
    ) -> CGRect? {
        guard total > 0, slot >= 0, slot < total,
              camera.zoom > 0,
              camera.viewportSize.width > 0, camera.viewportSize.height > 0
        else { return nil }
        let center = anchor ?? camera.center

        // 视口换算成世界尺寸：单元格跟着缩放走，"中心区域"始终是看得见的那一块。
        let worldViewport = CGSize(
            width: camera.viewportSize.width / camera.zoom,
            height: camera.viewportSize.height / camera.zoom
        )
        let cell = CGSize(
            width: worldViewport.width * cellFraction,
            height: worldViewport.height * cellFraction
        )
        let columns = min(total, self.columns)
        let rows = (total + columns - 1) / columns
        let gridSize = CGSize(
            width: CGFloat(columns) * cell.width + CGFloat(columns - 1) * gap,
            height: CGFloat(rows) * cell.height + CGFloat(rows - 1) * gap
        )
        // 网格整体居中于锚点（默认视口中心）。
        let firstCellCenter = CGPoint(
            x: center.x - gridSize.width / 2 + cell.width / 2,
            y: center.y - gridSize.height / 2 + cell.height / 2
        )
        let column = slot % columns
        let row = slot / columns
        let cellCenter = CGPoint(
            x: firstCellCenter.x + CGFloat(column) * (cell.width + gap),
            y: firstCellCenter.y + CGFloat(row) * (cell.height + gap)
        )

        let aspect = pixelSize.width / max(1, pixelSize.height)
        var size = cell
        if aspect > cell.width / cell.height {
            size.height = cell.width / aspect
        } else {
            size.width = cell.height * aspect
        }
        return CGRect(
            origin: CGPoint(x: cellCenter.x - size.width / 2, y: cellCenter.y - size.height / 2),
            size: size
        )
    }
}
