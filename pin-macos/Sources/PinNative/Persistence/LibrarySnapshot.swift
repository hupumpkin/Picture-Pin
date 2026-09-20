import Foundation
import GRDB

/// 启动时读一次库，之后**主线程只读它**。
///
/// ## 为什么要有这一层（而不是让界面直接查库）
///
/// 因为"主线程不碰 I/O"这条线要划在一个**结构上挡得住**的位置。让界面拿着
/// `SceneStore` 的话，下一个人写 `panel.assets` 时很自然会写成一个查库的属性——
/// 它读起来完全正常，而它每次求值都是一次磁盘读取。快照把这条路堵死：
/// 界面手上没有库，只有一份内存里的值。
///
/// ## 快照是**只读的**，改动不回写
///
/// 它不是"内存里的数据库"——那样就有两份真相。改动一律走
/// `LibraryWriting`（`BoardStore` → `SceneWriteScheduler` → 库），快照只在
/// 启动那一次、以及导入之后重建。
///
/// ## 它不装什么（都是刻意的）
///
/// - **相机**：每次启动回初始视角（§7 第 7 条）
/// - **选中**：不是持久状态，是撤销历史里的一步（§7 第 6 条）
/// - **已解码的像素**：那是 `ImageCache` 的事，与"库里有什么"无关
struct LibrarySnapshot: Sendable {

    /// 全部画布，按 `sort` 排好。
    var boards: [Board]
    /// 每块画布的元素，按绘制顺序排好。
    var elements: [UUID: [CanvasElement]]
    /// 全部素材，按 `added_at DESC` 排好（面板的次序）。
    var assets: [AssetRecord]

    /// 空库。**没有画布**——"至少一块画布"这件事由 `BoardStore` 负责
    /// （它的不变量是 `boards` 永不为空），不在这里悄悄补一块：
    /// 补在这里的话，"用户删光了画布"与"库是空的"就分不开了。
    static let empty = LibrarySnapshot(boards: [], elements: [:], assets: [])

    func elements(in board: UUID) -> [CanvasElement] { elements[board] ?? [] }

    func asset(_ id: AssetID) -> AssetRecord? { assets.first { $0.id == id } }

    /// 库整体是不是空的。`--library-report` 用它区分"全新空库"与"读失败"。
    var isEmpty: Bool { boards.isEmpty && assets.isEmpty }

    var elementCount: Int { elements.values.reduce(0) { $0 + $1.count } }

    // MARK: - 读

    /// 一次读完。
    ///
    /// **一次**是重点：三张表分别读三次的话，中间隔着两次 `await`，而启动是
    /// 允许有别的写入发生的（另一个窗口、或者上一次退出时还没写完的调度器）。
    /// 一次读拿到的是同一个事务里的三个结果，彼此自洽——比如"某块画布一个元素
    /// 都没有"与"这块画布还不存在"不可能同时成立，也就不会画出一块空画布。
    ///
    /// 读在 GRDB 自己的队列上执行（见 `LibraryDatabase.read`），所以这一次
    /// 数据库访问**不占主线程**——启动时主线程该干的是画第一帧。
    static func load(from database: LibraryDatabase) async throws -> LibrarySnapshot {
        try await database.read { db in
            let boards = try Row.fetchAll(
                db,
                sql: "SELECT * FROM board ORDER BY sort ASC, created_at ASC"
            ).map(SceneStore.board(from:))

            let assets = try Row.fetchAll(
                db,
                sql: "SELECT * FROM asset ORDER BY added_at DESC, id ASC"
            ).map(AssetStore.record(from:))

            // 分组在这里做，不在 SQL 里按画布循环：元素行很小（八个数字加两个
            // UUID），一次读回来再分组的峰值可以忽略；而按画布循环会把"一次读"
            // 变回"N 次读"——那正是上面那段话要避免的。
            //
            // `element` 行里带着 `board_id`，而 `CanvasElement` 自己没有这个字段
            // （它属于哪块画布由 `CanvasScene` 决定，元素不重复记一遍）。
            // 所以分组必须在这一层做：再往下走，这条信息就丢了。
            var byBoard: [UUID: [CanvasElement]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM element ORDER BY board_id ASC, z ASC") {
                guard let board = UUID(uuidString: row["board_id"] ?? ""),
                      let element = SceneStore.element(from: row)
                else { continue }
                byBoard[board, default: []].append(element)
            }

            return LibrarySnapshot(boards: boards, elements: byBoard, assets: assets)
        }
    }
}
