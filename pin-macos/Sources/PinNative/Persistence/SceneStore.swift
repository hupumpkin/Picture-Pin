import CoreGraphics
import Foundation
import GRDB

/// 画布与元素的读写。
///
/// ## 写入的粒度是「一次场景变更」，不是「整份场景」
///
/// 每次改动都整份重写的话，1000 个元素的画布每挪一下就是 1000 条 UPDATE——
/// 而"挪一下"正是最高频的写入源。`CanvasSceneChange` 已经把"变了什么"算好了
/// （`SceneGraph` 里那份唯一的同步契约），所以这里直接按它落库：
/// 插几条、改几条、删几条，其余一个字不动。
///
/// **没有"保存场景"这个方法**是有意的：有了它，调用方就会攒一堆改动再调一次，
/// 而"攒"意味着中间崩一次就丢一批。改动一来就落（由调度器合并），是最省心的口径。
struct SceneStore: Sendable {

    let database: LibraryDatabase

    // MARK: - 画布

    /// 全部画布，按用户排的顺序。
    func boards() async throws -> [Board] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM board ORDER BY sort ASC, created_at ASC")
                .map(Self.board(from:))
        }
    }

    func boardCount() async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM board") ?? 0
        }
    }

    /// 写入一块画布（不存在则插入）。`sort` 是它在画布列表里的位次。
    func saveBoard(_ board: Board, sort: Int) async throws {
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO board (id, name, created_at, sort) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, sort = excluded.sort
                """, arguments: [
                board.id.uuidString,
                board.name,
                board.createdAt.timeIntervalSince1970,
                sort,
            ])
        }
    }

    /// 删一块画布。**元素由外键连带删**（`ON DELETE CASCADE`）。
    func deleteBoard(_ id: UUID) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM board WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// 把画布列表的**顺序**整体写一遍（重排之后调）。
    func saveBoardOrder(_ boards: [Board]) async throws {
        try await database.write { db in
            for (index, board) in boards.enumerated() {
                try db.execute(
                    sql: "UPDATE board SET sort = ? WHERE id = ?",
                    arguments: [index, board.id.uuidString]
                )
            }
        }
    }

    // MARK: - 元素

    /// 一块画布上的全部元素，按绘制顺序（小的在下）。
    func elements(in boardID: UUID) async throws -> [CanvasElement] {
        try await database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM element WHERE board_id = ? ORDER BY z ASC",
                arguments: [boardID.uuidString]
            ).compactMap(Self.element(from:))
        }
    }

    /// 元素条数。`--library-report` 要用。
    func elementCount() async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM element") ?? 0
        }
    }

    /// 落一次场景变更。
    ///
    /// ## 顺序：先删后插再改
    ///
    /// 和渲染器那边（`LayerRenderer.apply`）是同一条理由：同一个 id 在 removed
    /// 和 inserted 里同时出现时（换画布场景），先删才不会撞主键。
    ///
    /// ## 为什么 `order` 要单独处理
    ///
    /// 因为"顺序变了"不等于"元素变了"——把 A 提到最前时 B..Z 的相对顺序也变了，
    /// 但它们的外框一个都没动。`CanvasElement` 整体比较不会把它们放进 `updated`
    /// （`order` 也在被比较的字段里，所以其实会），而**渲染顺序是用户看得见的**：
    /// 恢复之后叠放次序反了，是那种"说不上哪里不对但就是不对"的错。
    /// 所以 `change.order` 非空时，按它把 `z` 整体重写一遍。
    func apply(_ change: CanvasSceneChange, in boardID: UUID) async throws {
        guard !change.isEmpty else { return }
        try await database.write { db in
            try Self.apply(change, in: boardID, to: db)
        }
    }

    private static func apply(
        _ change: CanvasSceneChange,
        in boardID: UUID,
        to db: GRDB.Database
    ) throws {
        if !change.removed.isEmpty {
            let placeholders = Array(repeating: "?", count: change.removed.count)
                .joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM element WHERE id IN (\(placeholders))",
                arguments: StatementArguments(change.removed.map { $0.raw.uuidString })
            )
        }
        for element in change.inserted {
            try insert(element, in: boardID, to: db)
        }
        for element in change.updated {
            try db.execute(sql: """
                UPDATE element SET asset_id = ?, x = ?, y = ?, w = ?, h = ?, z = ?
                WHERE id = ?
                """, arguments: [
                Self.assetIDString(of: element),
                element.frame.origin.x,
                element.frame.origin.y,
                element.frame.size.width,
                element.frame.size.height,
                element.order,
                element.id.raw.uuidString,
            ])
        }
        // 顺序单独收尾：它在 inserted/updated 之外还可能是**唯一**的变化。
        if let order = change.order {
            for (index, id) in order.enumerated() {
                try db.execute(
                    sql: "UPDATE element SET z = ? WHERE id = ? AND z <> ?",
                    arguments: [index, id.raw.uuidString, index]
                )
            }
        }
    }

    private static func insert(_ element: CanvasElement, in boardID: UUID, to db: GRDB.Database) throws {
        try db.execute(sql: """
            INSERT INTO element (id, board_id, asset_id, x, y, w, h, z)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                x = excluded.x, y = excluded.y, w = excluded.w, h = excluded.h, z = excluded.z
            """, arguments: [
            element.id.raw.uuidString,
            boardID.uuidString,
            assetIDString(of: element),
            element.frame.origin.x,
            element.frame.origin.y,
            element.frame.size.width,
            element.frame.size.height,
            element.order,
        ])
    }

    /// 元素引用的素材 ID。
    ///
    /// `CanvasElement.Kind` 目前只有一种，`switch` 写成穷举而不是 `if case`：
    /// 加第二种元素（文字、字体样张）时**编译器会在这里报错**，而那时"忘了给新
    /// 元素写库"正是最容易漏的一处——`asset_id` 那一列是 NOT NULL。
    private static func assetIDString(of element: CanvasElement) -> String {
        switch element.kind {
        case .image(let asset): asset.raw.uuidString
        }
    }

    // MARK: - 行映射

    /// 行 → 画布。
    static func board(from row: Row) -> Board {
        Board(
            id: UUID(uuidString: row["id"] ?? "") ?? UUID(),
            name: row["name"] ?? "",
            createdAt: Date(timeIntervalSince1970: row["created_at"] ?? 0)
        )
    }

    /// 行 → 元素。
    ///
    /// 认不出来的行返回 `nil`（调用方 `compactMap` 掉），而不是造一个空元素：
    /// **宁可少一个元素，不要画布上多一个 0×0 的幽灵**——后者会让"定位到全部内容"
    /// 把视野拉到莫名其妙的地方，而且它看不见、选不中、删不掉。
    static func element(from row: Row) -> CanvasElement? {
        guard let id = CanvasElementID(string: row["id"] ?? ""),
              let asset = AssetID(string: row["asset_id"] ?? "")
        else { return nil }
        return CanvasElement(
            id: id,
            kind: .image(asset: asset),
            frame: CGRect(
                x: row["x"] ?? 0,
                y: row["y"] ?? 0,
                width: row["w"] ?? 0,
                height: row["h"] ?? 0
            ),
            order: row["z"] ?? 0
        )
    }
}

// MARK: - 落库的调度

/// 库的写入口。`BoardStore` 通过它在**每一条**改动路径上落库。
///
/// ## 为什么要经过一层协议，而不是让 `BoardStore` 直接拿着 `SceneStore`
///
/// 因为 `BoardStore` 在 `Canvas/` 里，而 GRDB 只许出现在 `Persistence/`。
/// 更重要的是：**协议让"哪几条路会落库"变成编译器能查的事**——`BoardStore` 里
/// 每一处 `boards` 的改动都得走这几个方法，漏掉一处就是"改了但重启就没了"，
/// 而那种缺陷在开发机上永远复现不了（开发时很少重启）。
@MainActor
protocol LibraryWriting: AnyObject {
    /// 画布被新建或改名。`sort` 是它在列表里的位次。
    func persist(board: Board, sort: Int)
    /// 画布被删除，`remaining` 是删完之后剩下的（它们的位次都往前挪了）。
    func removeBoard(_ id: UUID, remaining: [Board])
    /// 场景变了一次。**同一个画布上连续多次变更会被合并**（见 `SceneWriteScheduler`）。
    func persist(_ change: CanvasSceneChange, in board: UUID)
    /// 立刻把待写的都写完。退出、切画布、导入之后调。
    func flush() async
}

/// 把写库的活儿排成一队，**安静一段时间之后统一写**。
///
/// ## 为什么需要它（§3.1 的三句话，逐句对应）
///
/// - 「拖动中不写、松手后写」：拖动每动一像素就是一次 `setFrame`，每次落库
///   都是几条 UPDATE 加一次事务提交，而它跑在**用户正盯着看**的那段时间里。
///   所以：来一个变更先收下，**安静 `quietPeriod` 之后**才写。手一停就写，
///   手不停就一直攒着。
/// - 「写入粒度与命令对齐」：攒的单位是 `CanvasSceneChange`，不是"整份场景"。
/// - 「退出与切画布时强制刷盘」：`flush()` 跳过安静期，立刻写。
///
/// ## 为什么是一条款式队列，而不是一个 `[画布: 变更]` 字典
///
/// 字典会**打乱顺序**：`新建画布` 与 `往这块画布插元素` 是两件事，而元素的
/// `asset_id` 外键在那儿等着画布先存在。队列天然保序，合并只在**队尾**做
/// （见 `persist(_:in:)`），所以"合并"永远不会跨过一次删除或一次建画布。
///
/// ## 写失败为什么要放回去
///
/// 丢掉的话，"磁盘满了"就变成了一次**静默的数据丢失**——用户看到的是一切正常，
/// 直到重启才发现最后那几步没留下。放回去之后下一次安静期还会再试，
/// 同时把错误报上去（`onError`）。
@MainActor
final class SceneWriteScheduler: LibraryWriting {

    /// 安静多久之后落库。250 ms 是"手停下来的感觉"——比一帧长得多，比一次
    /// 停顿短得多。自检里传 0，这样断言不必等。
    static let defaultQuietPeriod: TimeInterval = 0.25

    /// 一次待写的活儿。
    private enum Job {
        case board(Board, sort: Int)
        case deleteBoard(UUID, remaining: [Board])
        case scene(CanvasSceneChange, board: UUID)
    }

    private let store: SceneStore
    private let quietPeriod: TimeInterval

    private var queue: [Job] = []
    /// 正在跑的排空任务。`nil` 表示没有在写。
    private var drainTask: Task<Void, Never>?
    private var flushTask: Task<Error?, Never>?
    /// 每换一次排空任务就 +1。被 `flush()` 顶掉的那一次醒来后靠它认出自己已经过气。
    private var drainGeneration = 0
    /// 写失败的回调。**必须有人接**：静默失败的形态是"界面一切正常、重启全没了"。
    var onError: (@MainActor (Error) -> Void)?

    /// 真正提交过多少个活儿（合并之后）。断言用它证明"合并真的发生了"。
    private(set) var commitCount = 0
    /// 收下过多少个活儿。和 `commitCount` 一起看：前者远大于后者才是合并生效。
    private(set) var submittedCount = 0
    /// 失败后放回队列的次数。**不是 0 就说明有东西没写进去**，报告要打印它。
    private(set) var requeueCount = 0

    init(store: SceneStore, quietPeriod: TimeInterval = SceneWriteScheduler.defaultQuietPeriod) {
        self.store = store
        self.quietPeriod = quietPeriod
    }

    func persist(board: Board, sort: Int) {
        submittedCount += 1
        queue.append(.board(board, sort: sort))
        scheduleDrain()
    }

    func removeBoard(_ id: UUID, remaining: [Board]) {
        submittedCount += 1
        queue.append(.deleteBoard(id, remaining: remaining))
        scheduleDrain()
    }

    func persist(_ change: CanvasSceneChange, in board: UUID) {
        guard !change.isEmpty else { return }
        submittedCount += 1
        // **只在队尾合并且只合并同一个画布**：队尾是这次拖动的前一次改动，
        // 合并它们丢掉的只是中间帧。跨过别的活儿合并就不安全了（见类型说明）。
        if case .scene(let previous, let previousBoard) = queue.last, previousBoard == board {
            queue[queue.count - 1] = .scene(previous.merging(change), board: board)
        } else {
            queue.append(.scene(change, board: board))
        }
        scheduleDrain()
    }

    /// 把安静期跳过去，立刻写完。
    ///
    /// Success means the queue is empty. On failure the job stays queued and
    /// `flushReportingFailure()` returns the error to callers that need a receipt.
    func flush() async {
        _ = await flushReportingFailure()
    }

    /// Flushes pending writes and reports whether any job is still queued after a failure.
    /// The old drain must finish before a new one starts, preserving board-before-element order.
    func flushReportingFailure() async -> Error? {
        if let flushTask { return await flushTask.value }
        let task = Task { @MainActor in
            let previous = drainTask
            previous?.cancel()
            drainTask = nil
            drainGeneration += 1
            await previous?.value
            return await drain()
        }
        flushTask = task
        let result = await task.value
        flushTask = nil
        if result == nil, !queue.isEmpty { scheduleDrain() }
        return result
    }

    // MARK: - 内部

    private func scheduleDrain() {
        guard drainTask == nil, flushTask == nil else { return }
        drainGeneration += 1
        let generation = drainGeneration
        drainTask = Task { [quietPeriod] in
            if quietPeriod > 0 {
                try? await Task.sleep(nanoseconds: UInt64(quietPeriod * 1_000_000_000))
            }
            // 被 `flush()` 顶掉的那一次：醒来时队列已经交给别人了，直接退场。
            //
            // 不认这一下的话，两条排空会同时挂在同一个队列上。它们不会重复写
            // （取活儿是 `removeFirst`，谁拿到算谁的），但**`commitCount` 会在
            // `flush()` 返回之后才涨**——于是"刷盘返回时东西已经写完"这句话
            // 就只是在多数情况下成立，而它正是退出前刷盘要依赖的那一条。
            guard generation == self.drainGeneration else { return }
            _ = await self.drain()
        }
    }

    /// 把队列里的活儿一条条写掉。
    ///
    /// 每写完一条就重取队列（写的过程中可能又有新的进来），所以一次 `drain`
    /// 会一直干到队列真的空了为止。写失败的那一条**插回队首**并立刻停下——
    /// 后面的活儿可能依赖它（建画布在前、插元素在后），跳过去写只会写坏。
    private func drain() async -> Error? {
        while !queue.isEmpty {
            let job = queue.removeFirst()
            do {
                try await perform(job)
                commitCount += 1
            } catch {
                queue.insert(job, at: 0)
                requeueCount += 1
                drainTask = nil
                onError?(error)
                return error
            }
        }
        drainTask = nil
        return nil
    }

    private func perform(_ job: Job) async throws {
        switch job {
        case .board(let board, let sort):
            try await store.saveBoard(board, sort: sort)
        case .deleteBoard(let id, let remaining):
            try await store.deleteBoard(id)
            // 删掉一块之后，后面那些的位次都往前挪了一位。不重写的话，
            // 下次启动按 sort 排出来会有一个空位——顺序看着"错了一格"。
            try await store.saveBoardOrder(remaining)
        case .scene(let change, let board):
            try await store.apply(change, in: board)
        }
    }
}

// MARK: - 变更合并

extension CanvasSceneChange {

    /// 把后一次变更并进前一次。**只在调度器的安静期内使用**（见它的说明）。
    ///
    /// 规则只有一条：**按元素 ID 取最后一次**。`order` 取非空的那一个（后一次
    /// 有就用后一次的——它是完整顺序，不是增量）。
    func merging(_ next: CanvasSceneChange) -> CanvasSceneChange {
        var merged = self

        // 先按 id 归并 inserted / updated，再决定谁在最后。
        var insertedByID: [CanvasElementID: CanvasElement] = [:]
        for element in merged.inserted { insertedByID[element.id] = element }
        var updatedByID: [CanvasElementID: CanvasElement] = [:]
        for element in merged.updated { updatedByID[element.id] = element }
        var removed = Set(merged.removed)

        for element in next.inserted {
            removed.remove(element.id)
            if insertedByID[element.id] != nil {
                insertedByID[element.id] = element
            } else {
                // 已经插过又改过：仍然是"插入"，用最后的外框。
                insertedByID[element.id] = element
                updatedByID[element.id] = nil
            }
        }
        for element in next.updated {
            if insertedByID[element.id] != nil {
                insertedByID[element.id] = element
            } else {
                updatedByID[element.id] = element
            }
        }
        for id in next.removed {
            insertedByID[id] = nil
            updatedByID[id] = nil
            removed.insert(id)
        }

        merged.inserted = Array(insertedByID.values)
        merged.updated = Array(updatedByID.values)
        merged.removed = Array(removed)
        merged.order = next.order ?? merged.order
        return merged
    }
}
