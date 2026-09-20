import CoreGraphics
import Foundation

/// `AssetStore` 的迟到接线（§3.4）。
///
/// 素材来源目录在 `WorkspaceModel.init` 里就建好，而库要到 `prepareStorage()`
/// 才打开——真实提供者出生时拿不到 `AssetStore`。这个盒子让"打开库"之后
/// store 能送到已经建好的提供者手里：提供者每次 `refresh()` 都问它一遍，
/// 而不是在 init 时问一遍就死心（那会让"先建提供者、后开库"变成死局，
/// 刷新永远只能拿到 nil）。
@MainActor
final class AssetStoreLookup {
    var store: AssetStore?
    init(store: AssetStore? = nil) { self.store = store }
}

/// 解码并发闸门（§3.4：只给可见行发请求之外，还要限制并发解码数）。
///
/// 几百条素材快速滚动时，可见行一轮会同时发出十来个解码请求；每个请求单独
/// 看都很小，但它们是并行的。闸门把"同时在解"的数目压在 `limit` 以内，
/// 超出的排队等位。
///
/// ## 取消安全
///
/// 行滚出视口时，SwiftUI 会取消那一行的 `.task`。排队等位的请求必须能被
/// 取消摘除——不然每滚走一行就有一个任务永远挂在队列里，闸门迟早被
/// 幽灵等待者塞满。被取消的等待者返回 `false`：没拿到过位子，调用方
/// 不解码、也不还位子。
@MainActor
final class ThumbnailGate {
    let limit: Int

    private var active = 0
    /// 等待者。状态全部在主 actor 上读写（闸门类型是 `@MainActor`）；
    /// `@unchecked Sendable` 只是为了过 `onCancel` 闭包的捕获检查——
    /// 那个闭包只把摘除投递回主 actor，不碰等待者本身。
    private final class Waiter: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Never>?
        var cancelled = false
    }
    private var queue: [Waiter] = []

    init(limit: Int) { self.limit = limit }

    /// 等一个解码位子。`false` = 等待期间被取消（没拿到位子）。
    func acquire() async -> Bool {
        if active < limit {
            active += 1
            return true
        }
        if Task.isCancelled { return false }
        let waiter = Waiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.continuation = continuation
                queue.append(waiter)
            }
        } onCancel: {
            // onCancel 可能不在主线程；闸门状态在主 actor 上，投递回去摘除。
            Task { @MainActor [weak self] in self?.removeWaiter(waiter) }
        }
        return !waiter.cancelled
    }

    /// 还一个位子。与成功拿到位子的 `acquire()` 一一配对（拿到位子后
    /// 即使任务被取消，也要还——位子是资源，不是任务的一部分）。
    func release() {
        if let next = queue.first {
            queue.removeFirst()
            next.continuation?.resume()
            next.continuation = nil
        } else {
            active -= 1
        }
    }

    /// 把被取消的等待者摘出队列并唤醒它。摘除和唤醒必须原子：
    /// 先摘后唤，`release()` 就永远看不到它、不会二次唤醒；
    /// 唤过一次之后 `continuation` 置空，后到的 `release()` 也会因
    /// 队列里没有它而安然无事。
    private func removeWaiter(_ waiter: Waiter) {
        guard let index = queue.firstIndex(where: { $0 === waiter }) else { return }
        queue.remove(at: index)
        waiter.cancelled = true
        waiter.continuation?.resume()
        waiter.continuation = nil
    }
}

/// 截图来源的真实现（§3.4）：条目来自素材库（`added_at DESC`，新的在前），
/// 缩略图走共享 `ImageProvider`——面板与画布同一个实例、同一份缓存，
/// 不新建缩略图体系（各缓存一份 = 内存翻倍，`MaterialItem` 的说明）。
///
/// 四态齐全：`.idle`（还没拉过）→ `.loading` → `.loaded` / `.failed(原因)`。
/// 失败**必须说得出口**：素材读取失败的表现是「面板一直空着」，和
/// 「确实没有素材」长得一模一样——面板的失败分支就是为这个留的
/// （`MaterialSourceContent` 的说明）。
@MainActor
@Observable
final class ScreenshotMaterialProvider: MaterialProvider {

    let environment: AppEnvironment
    private(set) var content: MaterialSourceContent = .idle

    /// 库的迟到接线。每次 `refresh()` 都问它一遍。
    private let lookup: AssetStoreLookup?
    /// 共享图片管线。目录在测试里可以只带环境构建，那时不给，
    /// 缩略图请求返回 `nil`，行视图退回图标占位。
    private let images: (any ImageProvider)?
    /// 缩略图解码的并发闸门。4 个解码位：可见行一般十来个，
    /// 4 个同时在解、其余排队，滚动时不会一次把 CPU 顶满。
    private let gate = ThumbnailGate(limit: 4)

    init(
        environment: AppEnvironment,
        assets lookup: AssetStoreLookup? = nil,
        images: (any ImageProvider)? = nil
    ) {
        self.environment = environment
        self.lookup = lookup
        self.images = images
    }

    func refresh() async {
        content = .loading
        // 库还没打开：这是"还没准备好"，不是"没有素材"。写成失败而非空，
        // 用户看到的是"素材库还没准备好 + 重试"，而不是一个无从解释的空面板。
        guard let store = lookup?.store else {
            content = .failed("素材库还没准备好")
            return
        }
        do {
            let records = try await store.allAssets()
            content = .loaded(records.map(Self.item(from:)))
        } catch {
            content = .failed("读不了素材库：\(error.localizedDescription)")
        }
    }

    /// 条目身份 = 素材身份：`MaterialItemID` 直接取 `AssetID` 的 UUID，
    /// 两次刷新之间同一条素材的条目是同一个。身份每次刷新都换新的话，
    /// SwiftUI 会把列表当成全新内容整个重排，看起来像"素材在乱跳"。
    static func item(from record: AssetRecord) -> MaterialItem {
        MaterialItem(
            id: MaterialItemID(record.id.raw),
            title: record.originalFilename,
            thumbnail: record.id,
            kind: .image
        )
    }

    /// 缩略图请求（§3.4）：走共享 `ImageProvider`，先过闸门限并发。
    /// 拿到位子的请求即使随后被取消，也照常还位子（`defer`）。
    func thumbnail(for item: MaterialItem, targetPixelSize: CGSize) async -> ImageRequestResult? {
        guard let images, let asset = item.thumbnail else { return nil }
        guard await gate.acquire() else { return nil }
        defer { gate.release() }
        return await images.image(for: asset, targetPixelSize: targetPixelSize)
    }
}
