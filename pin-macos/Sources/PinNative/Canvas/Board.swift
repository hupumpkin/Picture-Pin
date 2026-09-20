import Foundation
import Observation

/// 一块画布。
///
/// 本轮只有一块（路线图 §6：「本轮只开放一个默认画布，模型保留 Board ID」），
/// 但这个类型现在就是真的：它有标识、有名字、有创建时间，而 `CanvasScene.boardID`
/// 一直存着它的标识。
struct Board: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// 画布集合与当前画布。
///
/// ## 为什么现在就做，而不是等真的要多画布时再说
///
/// 第一版 `WorkspaceModel.scene` 是个单数字段：`let scene: CanvasScene`。
/// 加多画布要把它改成复数，而届时依赖它的至少有相机、工具栏、快照工具、
/// 自检和宿主视图的绑定——**结构性的改动被推迟到依赖最多的时候**。
///
/// 现在把它收进一个集合，成本只是几行；之后加多画布就变成"加一个画布列表 UI、
/// 加一次 SQLite 持久化"，是加法而不是改结构。
///
/// ## 这里为什么也管相机和选择
///
/// 因为它们和画布**一一对应**，不是全局的：
/// - 换一块画布再换回来，视角应该还在原处。共享一个相机会让另一块画布的内容
///   "跳"到别处，而且这是那种一开始不难用、素材一多就很难受的毛病。
/// - 选择更是如此：选择里存的是元素 ID，切到别的画布后那些 ID 根本不存在，
///   覆盖层会照着空位置画选择框。
///
/// 两者如果留在外面当全局状态，加多画布时就一定会漏掉其中一个。
///
/// ## 不变量
///
/// `boards` **永不为空**。`init` 至少建一块，`remove` 拒绝删掉最后一块。
/// 所有取当前画布的访问器都依赖这一条。
@MainActor
@Observable
final class BoardStore {

    private(set) var boards: [Board]
    private(set) var activeBoardID: Board.ID

    private var scenes: [Board.ID: CanvasScene]
    private var cameras: [Board.ID: CanvasCamera]
    private var selections: [Board.ID: Set<CanvasElementID>]

    /// 落库的入口。**每一条改动路径都要经过它**（见 `LibraryWriting`）。
    ///
    /// 刻意是 `weak`：库比这个 store 活得久（退出时要靠它刷盘），反过来持有
    /// 会让"谁先销毁"变成一个问题。而它**不该**是可选链上的一次静默跳过——
    /// 没接线的表现是"改了但重启就没了"，所以自检里有一条断言直接钉住
    /// "接线之后每一次改动都落库了"。
    @ObservationIgnored weak var library: (any LibraryWriting)?

    /// 从快照恢复。
    ///
    /// 空快照 = 全新空库：**建一块默认画布**。这一步在这里而不是在
    /// `LibrarySnapshot` 里，是因为"至少有一块画布"是这个类型的不变量
    /// （所有取当前画布的访问器都依赖它），而快照只是"库里有什么"的忠实记录
    /// ——库里一块画布都没有，那是真的。
    ///
    /// 相机与选中**不从快照里读**：两者都不持久化（§7 第 6、7 条）。
    /// 快照里根本没有它们，所以这里也没有任何"顺手恢复一下"的余地。
    init(snapshot: LibrarySnapshot = .empty) {
        if snapshot.boards.isEmpty {
            let board = Board(name: "画布 1")
            self.boards = [board]
            self.activeBoardID = board.id
            self.scenes = [board.id: CanvasScene(boardID: board.id)]
            self.cameras = [board.id: .initial]
            self.selections = [board.id: []]
        } else {
            self.boards = snapshot.boards
            self.activeBoardID = snapshot.boards[0].id
            var scenes: [Board.ID: CanvasScene] = [:]
            var cameras: [Board.ID: CanvasCamera] = [:]
            var selections: [Board.ID: Set<CanvasElementID>] = [:]
            for board in snapshot.boards {
                scenes[board.id] = CanvasScene(
                    boardID: board.id,
                    elements: snapshot.elements(in: board.id)
                )
                cameras[board.id] = .initial
                selections[board.id] = []
            }
            self.scenes = scenes
            self.cameras = cameras
            self.selections = selections
        }
    }

    convenience init(board: Board) {
        self.init(snapshot: LibrarySnapshot(boards: [board], elements: [:], assets: []))
    }

    // MARK: - 当前画布

    private var activeIndex: Int {
        boards.firstIndex { $0.id == activeBoardID } ?? 0
    }

    /// 当前画布的序号，从 1 开始。供界面显示"第 n / m 块"。
    ///
    /// 对外 1 起、对内 0 起：`boards` 是数组，但"第 0 块画布"不是人话。
    /// 转换只在这一处做，免得每个显示画布序号的地方各自 +1。
    var activeIndexDisplay: Int { activeIndex + 1 }

    var activeBoard: Board { boards[activeIndex] }

    /// 当前画布的场景。
    ///
    /// 只读：改动一律走 `CanvasSceneCommand` → `applyScene(_:)`，
    /// 场景的写入路径只有一条，避免"两个地方各改一半"。
    var activeScene: CanvasScene { scenes[activeBoardID] ?? CanvasScene(boardID: activeBoardID) }

    /// 当前画布的相机。`CanvasHostView` 的直接操控与工具栏按钮都改这一个值。
    var activeCamera: CanvasCamera {
        get { cameras[activeBoardID] ?? .initial }
        set { cameras[activeBoardID] = newValue }
    }

    /// 当前画布选中的元素。选择逻辑属于 Codex 的 `SelectionController`，
    /// 这里只持有结果供覆盖层与工具栏读取。
    var activeSelection: Set<CanvasElementID> { selections[activeBoardID] ?? [] }

    // MARK: - 查询

    func scene(for id: Board.ID) -> CanvasScene? { scenes[id] }
    func camera(for id: Board.ID) -> CanvasCamera? { cameras[id] }
    func selection(for id: Board.ID) -> Set<CanvasElementID> { selections[id] ?? [] }

    // MARK: - 管理
    //
    // 这组操作现在就可用且自检覆盖。本轮**没有对应的界面**——
    // 完整的多画布管理属于后续阶段（路线图 §6）。先让它们是对的，
    // 加界面时就不用同时怀疑底层。

    /// 切到指定画布。已经是当前画布时什么都不做。
    func select(_ id: Board.ID) {
        guard id != activeBoardID, boards.contains(where: { $0.id == id }) else { return }
        activeBoardID = id
    }

    /// 新建一块画布并切过去。
    ///
    /// 名字的规则和 `rename` **是同一条**（去首尾空白、不许空）。区别只在空白时
    /// 怎么办：这里回落到默认名，而不是拒绝——新建画布这件事必须发生（调用方
    /// 还会切过去），拒绝只会留下"点了新建却什么都没发生"。独立复审报的是这两处
    /// 规则不一致：`rename` 挡住空白名，`addBoard` 却收下了，于是一块叫 `"   "`
    /// 的画布出现在界面上，用户看到的是"没有名字的画布"，而数据里它是合法的。
    @discardableResult
    func addBoard(named name: String? = nil) -> Board {
        let board = Board(name: normalizedName(name) ?? nextDefaultName())
        boards.append(board)
        scenes[board.id] = CanvasScene(boardID: board.id)
        cameras[board.id] = .initial
        selections[board.id] = []
        activeBoardID = board.id
        // 落库放在**这个函数里面**，不是让调用方自己记得调。`addBoard` 有三个
        // 调用点（工具栏、调试菜单、自检），漏掉一处的表现是"新建的画布重启就没了，
        // 而里面的元素还在库里的孤儿状态"——那种错要查很久。
        library?.persist(board: board, sort: boards.count - 1)
        return board
    }

    func rename(_ id: Board.ID, to name: String) {
        guard let trimmed = normalizedName(name),
              let index = boards.firstIndex(where: { $0.id == id })
        else { return }
        boards[index].name = trimmed
        library?.persist(board: boards[index], sort: index)
    }

    /// 画布名的唯一规则：去掉首尾空白，空的算没给。返回 `nil` 表示"这个名字不能用"。
    ///
    /// 收在一处，`addBoard` 与 `rename` 才不可能各写一条——复审报的那条缺陷正是
    /// 两条规则分家的结果。
    private func normalizedName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// 删除一块画布。**拒绝删除最后一块**（不变量：`boards` 永不为空），
    /// 返回是否真的删掉了。
    @discardableResult
    func remove(_ id: Board.ID) -> Bool {
        guard boards.count > 1, let index = boards.firstIndex(where: { $0.id == id }) else {
            return false
        }
        boards.remove(at: index)
        scenes[id] = nil
        cameras[id] = nil
        selections[id] = nil
        // 删的是当前画布时落到相邻的一块，而不是留下一个悬空的 activeBoardID。
        if activeBoardID == id {
            activeBoardID = boards[min(index, boards.count - 1)].id
        }
        // `remaining` 一起交出去：删掉一块之后，后面那些的 `sort` 都往前挪了一位。
        library?.removeBoard(id, remaining: boards)
        return true
    }

    private func nextDefaultName() -> String {
        let taken = Set(boards.map(\.name))
        var index = boards.count + 1
        while taken.contains("画布 \(index)") { index += 1 }
        return "画布 \(index)"
    }

    // MARK: - 恢复

    /// 用快照里的内容**整体替换**当前状态。
    ///
    /// ## 为什么它可以替换，而不是逐块合并
    ///
    /// 因为它只在启动时跑一次，那一刻内存里的东西全部是"还没有内容的默认值"
    /// ——没有任何改动会被它盖掉。加一条"启动之后再调"的路就会有这个问题，
    /// 所以调用点只有一个（`WorkspaceModel.restore`）。
    ///
    /// ## 相机与选中被**重置**，不是被恢复
    ///
    /// 两者都不持久化（§7 第 6、7 条）。这里显式写一遍而不是"什么都不做"：
    /// 不写的话，将来某次改动把恢复挂到别处时，它们会带着**上一个库的**相机
    /// 和选中活下来——那种错看着像随机发生的。
    ///
    /// 空快照**不动**当前状态：空库要保留 `init` 建的那块默认画布，
    /// 否则启动之后界面上一块画布都没有（`boards` 永不为空是不变量）。
    func restore(from snapshot: LibrarySnapshot) {
        guard !snapshot.boards.isEmpty else { return }
        boards = snapshot.boards
        activeBoardID = snapshot.boards[0].id
        var scenes: [Board.ID: CanvasScene] = [:]
        var cameras: [Board.ID: CanvasCamera] = [:]
        var selections: [Board.ID: Set<CanvasElementID>] = [:]
        for board in snapshot.boards {
            scenes[board.id] = CanvasScene(
                boardID: board.id,
                elements: snapshot.elements(in: board.id)
            )
            cameras[board.id] = .initial
            selections[board.id] = []
        }
        self.scenes = scenes
        self.cameras = cameras
        self.selections = selections
    }

    // MARK: - 回写

    /// 画布宿主改过场景后回写。宿主是直接操控期间的权威版本，这里只跟着走。
    ///
    /// 按 `scene.boardID` 而不是 `activeBoardID` 落库：场景自己带着它属于哪块画布，
    /// 用当前画布去接会在切换的那一帧把两块画布的内容串在一起。
    ///
    /// **这里落的是差异，不是整份场景**：`Change` 是算好的（`CanvasScene.change`），
    /// 拿它去写库就只动真正变了的那几条。整份重写在 1000 元素的画布上是每次
    /// 一千条 UPDATE。
    func applyScene(_ scene: CanvasScene) {
        guard let previous = scenes[scene.boardID], previous != scene else { return }
        scenes[scene.boardID] = scene
        library?.persist(scene.change(from: previous), in: scene.boardID)
    }

    func applySelection(_ selection: Set<CanvasElementID>, for id: Board.ID) {
        guard selections[id] != nil, selections[id] != selection else { return }
        selections[id] = selection
    }

    /// 窗口尺寸变化后由 `CanvasHostView` 回报。
    ///
    /// **写给每一块画布**：视口尺寸是窗口的属性，不是画布的属性。只写当前画布的话，
    /// 切到另一块画布会拿到过期尺寸，「定位内容」就会按错的视口算缩放。
    func updateViewport(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        for id in Array(cameras.keys) where cameras[id]?.viewportSize != size {
            cameras[id]?.viewportSize = size
        }
    }
}
