import CoreGraphics
import Foundation

/// §3.9 的两条尺寸上限，**集中定义**——产品负责人定的口径，改一个数就能调整。
///
/// 两个类型放在同一个文件里，因为它们是一对：一个管"多大的文件收进来"，
/// 一个管"收进来之后一次解多大"。分开散在各自的使用点的话，调尺寸要改两处，
/// 而"改了这边忘了那边"的表现是：导入放行的图，解码时被自己人卡住。

/// 导入时拒绝离谱文件（§3.9 第 2 条）。
///
/// ## 为什么"尺寸上限"不是"格式白名单"
///
/// 格式仍然不写死（§7 第 5 条）：判定只走 ImageIO。这里卡的是**体量**——
/// 一张 50000×50000 的 TIFF 光落盘就是 9.3 GB，收进来之后每一次全档解码
/// 都会顶穿内存。拒绝它的时机在**复制之前**：一个字节都不落盘，也就不存在
/// "删半成品"这回事（§5）。
struct ImportPolicy {

    /// 最长边超过这个值 → 拒绝。
    var maxLongestEdge: CGFloat = 40_000

    /// 总像素超过这个值 → 拒绝。2 亿像素（≈ 200 MP）。
    var maxTotalPixels: Int = 200_000_000

    /// 拒绝时的提示文案。与数值放一起：文案是这条规则的一部分。
    static let tooLargeMessage = "这张图太大"

    /// 这张图收不收。用的是**摆正之后**的尺寸（`ImageFileFacts.pixelSize`），
    /// 与库里记的、渲染器用的同一口径。
    func rejects(_ pixelSize: CGSize) -> Bool {
        max(pixelSize.width, pixelSize.height) > maxLongestEdge
            || Int(pixelSize.width) * Int(pixelSize.height) > maxTotalPixels
    }
}

/// 单次解码的分配上限（§3.9 第 3 条）：任何一张图都不会把内存顶穿。
///
/// 默认 ≤ 64 MP（RGBA 8bit 下约 256 MB）。放行上限（200 MP）比它高是刻意的：
/// 200 MP 的图允许入库、允许上画布，只是**全档永远不解**——它被档位阶梯
/// 挡在 64 MP 以下（见 `maximumTier(forOriginal:)` 与 `LODTier.fitting` 的
/// 上限分支）。用户看得到的代价是放大到很深之后不再变清晰，而不是崩溃。
///
/// ## 这条上限靠档位阶梯保证，不靠解码前临时判断
///
/// 解码大小由档位决定（`LODTier.pixelSize(forOriginal:)`），所以把上限收进
/// 阶梯本身：`fitting` / `settled` 的结果**永远不会比 `maximumTier` 更细**。
/// 渲染器（选档）与提供者（解码）共用同一个阶梯，两边的口径天然一致——
/// 要是在解码前临时夹一刀，就会出现"记账说是这一档、像素其实是更粗那一档"
/// 的错账（B2 在迟滞上吃过的亏）。
struct DecodePolicy {

    /// 单次解码的总像素上限。64 MP ≈ 256 MB（RGBA 8bit）。
    var maxDecodedPixels: Int = 64_000_000

    /// 这张原图能解到的**最细档**：从全档往下，第一档总像素 ≤ 上限的档位。
    ///
    /// 原图本身在限内时返回全档（`.full`）——绝大多数素材都走这一支，
    /// 上限对它不存在。
    func maximumTier(forOriginal original: CGSize) -> LODTier {
        let totalPixels = Int(original.width) * Int(original.height)
        guard totalPixels > maxDecodedPixels else { return .full }
        // 每粗一档，总像素 ÷ 4。从 1/2 开始往下找，档位阶梯有限（≤ 5 档），
        // 到最粗一档（1/32）时任何合理上限都装得下。
        for level in 1...LODTier.maximumLevel {
            let divisor = CGFloat(1 << level)
            let width = max(1, (original.width / divisor).rounded(.down))
            let height = max(1, (original.height / divisor).rounded(.down))
            if Int(width) * Int(height) <= maxDecodedPixels {
                return LODTier(level: level)
            }
        }
        return LODTier(level: LODTier.maximumLevel)
    }
}
