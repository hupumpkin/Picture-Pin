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

    init(board: Board = Board(name: "画布 1")) {
        self.boards = [board]
        self.activeBoardID = board.id
        self.scenes = [board.id: CanvasScene(boardID: board.id)]
        self.cameras = [board.id: .initial]
        self.selections = [board.id: []]
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
        return board
    }

    func rename(_ id: Board.ID, to name: String) {
        guard let trimmed = normalizedName(name),
              let index = boards.firstIndex(where: { $0.id == id })
        else { return }
        boards[index].name = trimmed
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
        return true
    }

    private func nextDefaultName() -> String {
        let taken = Set(boards.map(\.name))
        var index = boards.count + 1
        while taken.contains("画布 \(index)") { index += 1 }
        return "画布 \(index)"
    }

    // MARK: - 回写

    /// 画布宿主改过场景后回写。宿主是直接操控期间的权威版本，这里只跟着走。
    ///
    /// 按 `scene.boardID` 而不是 `activeBoardID` 落库：场景自己带着它属于哪块画布，
    /// 用当前画布去接会在切换的那一帧把两块画布的内容串在一起。
    func applyScene(_ scene: CanvasScene) {
        guard scenes[scene.boardID] != nil, scenes[scene.boardID] != scene else { return }
        scenes[scene.boardID] = scene
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
