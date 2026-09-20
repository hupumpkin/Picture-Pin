import CoreGraphics
import Foundation

/// 剪贴板里"能拿来当素材"的东西（§4 第 2 条）。
///
/// ## 为什么剪贴板要分两种形态
///
/// 同一个 ⌘C，来源不同，粘出来的东西根本不是一回事：
///
/// - 在访达里复制一个文件 → 剪贴板里是**文件 URL**，原图还在磁盘上；
/// - 在浏览器里右键"复制图片"、或截图工具截图 → 剪贴板里是**位图数据**，
///   没有原文件。
///
/// 这两种必须分开走。硬把位图当文件 URL 处理，用户看到的是"粘贴没反应"；
/// 反过来把文件 URL 当位图处理，等于把原图重新编码一遍——分辨率没变，
/// 但文件名、格式、元数据全丢了。
///
/// ## 这一层不 import AppKit
///
/// 读 `NSPasteboard` 是平台边界（`PasteboardReader`），把这堆类型分好是政策。
/// 分开之后"位图数据该编成什么格式、叫什么名字"能在自检里直接构造来验，
/// 不必真的去动用户的剪贴板。
enum ClipboardPayload: Equatable {

    /// 剪贴板里是一批文件。访达复制、截图工具"存为文件"之后的复制都走这条。
    case fileURLs([URL])

    /// 剪贴板里是一张位图。**没有原文件**，需要编码落盘（§7 第 3 条）。
    ///
    /// - Parameters:
    ///   - data: **已经归一成 PNG** 的字节。归一放在读者那一侧，因为只有
    ///     那里知道剪贴板给的是 PNG 还是 TIFF；再往下的每一层都只当它是 PNG，
    ///     否则"这个 Data 到底是什么格式"要在三个地方各判一次。
    ///     存字节而不是 `CGImage`，是为了让它 `Equatable`，也为了让自检能
    ///     直接构造一个来跑完整条导入流水线。
    ///   - suggestedName: 落盘时用的显示名。位图没有文件名，得有一个，
    ///     否则素材面板里会出现一排没有名字的条目。扩展名参与
    ///     `AssetStore.ingest` 的落盘命名，所以必须是 `.png`。
    ///   - pixelSize: 像素尺寸。面板与网格排布在**入库之前**就要用它
    ///     （`GridPlacement` 按原比例放），而入库之后才知道的话，
    ///     第一帧就会按错误的尺寸摆一次。
    case image(data: Data, suggestedName: String, pixelSize: CGSize)

    /// 剪贴板里没有可用的图片。**与"空剪贴板"不是一回事**：复制了一段文字
    /// 也是这一支，而用户需要看到的文案是一样的——"剪贴板里没有图片"。
    case none

    /// 这份载荷里有没有东西可导。
    ///
    /// **一批空文件也算空**：拖放通道据此回答「收不收」，而回答 `true` 会让
    /// 源应用播放"已放入"动画——用户看到动画、画布上却什么都没有，比明确
    /// 拒收更让人困惑。
    var isEmpty: Bool {
        switch self {
        case .fileURLs(let urls): urls.isEmpty
        case .image: false
        case .none: true
        }
    }
}

/// 读剪贴板的通道。
///
/// 抽成协议只有一个理由：**自检不能动用户的剪贴板**。真剪贴板是全局单例，
/// 往里写一张测试图会把用户正在复制的东西顶掉——那比不测还糟。协议让自检
/// 传一个假的（`PasteboardReader` 是唯一的真实实现，也是唯一 import AppKit
/// 的那一处）。
/// 协议整体挂在主 actor 上，是因为真剪贴板（`NSPasteboard`）本来就是主线程
/// 独占的：它是个全局单例，`Sendable` 会假装它可以随便跨线程传——而这恰恰是
/// NSPasteboard 最不允许的一件事。导入流水线本来也在主 actor 上跑，
/// 挂在这里不让谁难受。
@MainActor
protocol ClipboardReading {
    /// 当前剪贴板里能当素材用的东西。**只读，不改剪贴板**。
    func read() -> ClipboardPayload
}

/// 不去读剪贴板的实现。给"只想跑导入流程、不关心剪贴板"的调用方用。
struct EmptyClipboard: ClipboardReading {
    func read() -> ClipboardPayload { .none }
}
