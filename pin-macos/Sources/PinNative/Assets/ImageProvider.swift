import CoreGraphics
import Foundation

/// 解码档位：相对原图按 2 的幂逐级减半。
///
/// ## 为什么档位必须是离散的
///
/// 因为它是**缓存键的一部分**。拿"当前需要多少像素"直接当键的话，每一级缩放
/// 都会产生一个新的键，缓存等于不存在——而缩放恰恰是最需要缓存的场景。
///
/// 2 的幂还有两个好处：档位数量是对数级的（4K 图从 1:1 到 1/32 只有 6 档），
/// 且整数倍降采样在缩放时不会额外引入锯齿。
///
/// ## 这一层和 B2 的分工
///
/// 这里只定义**档位本身**（怎么算、怎么落成像素尺寸）。**什么时候换档**
/// ——阈值、迟滞区间、预加载——是 B2 的策略，不在这里。
struct LODTier: Hashable, Sendable {
    /// 分母的指数：0 = 原分辨率，1 = 1/2，2 = 1/4，……
    let level: Int

    static let full = LODTier(level: 0)

    /// 最细的一档。再往下就是 1/64 以下，那种尺寸在画布上已经是纯色块，
    /// 留着只占缓存。
    static let maximumLevel = 5

    /// 覆盖给定像素需求所需的**最小**档位，也就是"够清晰但不过剩"的那一档。
    ///
    /// - Parameters:
    ///   - required: 当前显示实际需要多少像素（显示尺寸 × backingScaleFactor）。
    ///   - original: 原图像素尺寸。**必须由元数据提供，不能先解码再量**——
    ///     如果为了知道尺寸而解码一次，选档位这件事本身就没有意义了。
    static func fitting(_ required: CGSize, original: CGSize) -> LODTier {
        guard required.width > 0, required.height > 0,
              original.width > 0, original.height > 0
        else { return .full }

        var level = 0
        while level < maximumLevel {
            let divisor = CGFloat(1 << (level + 1))
            // 两个轴都要覆盖：只按宽度选档的话，细长图会在这个档位上被拉糊。
            if original.width / divisor < required.width
                || original.height / divisor < required.height {
                break
            }
            level += 1
        }
        return LODTier(level: level)
    }

    /// 该档位对应的解码像素尺寸。
    ///
    /// 向下取整到至少 1 像素：极端小图配极端粗的档位时不能算出 0，
    /// `CGContext` 拿到 0 宽会直接返回 nil。
    func pixelSize(forOriginal original: CGSize) -> CGSize {
        let divisor = CGFloat(1 << level)
        return CGSize(
            width: max(1, (original.width / divisor).rounded(.down)),
            height: max(1, (original.height / divisor).rounded(.down))
        )
    }

    /// **带迟滞**的选档：在 `fitting` 之上回答"要不要现在就换成这一档"。
    ///
    /// ## 两个方向不对称，这是刻意的
    ///
    /// - **更细**（`demanded` 比 `current` 细，或者 `current` 还没定）→ 立刻换。
    ///   不换就是画面糊，而糊不能忍。这一侧没有可调参数。
    /// - **更粗** → 一级一级往下走，**每降一级都要那一级把需求覆盖 `headroom` 倍**。
    ///   `headroom = 1` 就是"一路降到 `fitting` 的结果"，即 B1 的行为（没有迟滞）。
    ///
    /// ## 为什么是逐级判，而不是只判最终那一档
    ///
    /// 只判终点会在大幅缩小时卡住：从原分辨率一路缩到很粗的一档时，**终点那一档
    /// 必然没有余量**（它本来就是"刚好覆盖需求"的那一档），于是判定为"不许降"，
    /// 画面就一直停在最细的档上白占内存。逐级判没有这个问题——中间每一级都过得去
    /// 就往下走，走到终点前那一级停住。
    ///
    /// 返回值保证两件事：**永远不比 `demanded` 更粗**（不会停在糊的档上）、
    /// **永远不比 `current` 更细**（不会因为一次抖动就跳去解一张更大的图）。
    ///
    /// ## 为什么这个函数是纯的
    ///
    /// 迟滞最容易出的错是"在某个方向上永远换不了档"——那是一个**只有真实缩放
    /// 序列才碰得到**的状态，靠读代码看不出来。做成纯函数就能把整条缩放轨迹
    /// （来回抖动、单方向大跨步、反复跨越边界）在自检里直接跑完。
    static func settled(
        _ required: CGSize,
        original: CGSize,
        from current: LODTier?,
        headroom: CGFloat
    ) -> LODTier {
        let demanded = fitting(required, original: original)
        guard let current, demanded.level > current.level else { return demanded }

        let margin = max(1, headroom)
        var candidate = current
        while candidate.level < demanded.level {
            let next = LODTier(level: candidate.level + 1)
            // 更粗的一档要"够用还得有余量"才准降。两个轴都要满足，理由同 `fitting`：
            // 只看一个轴的话细长图会先在那个轴上被拉糊。
            let pixels = next.pixelSize(forOriginal: original)
            guard required.width * margin <= pixels.width,
                  required.height * margin <= pixels.height
            else { break }
            candidate = next
        }
        return candidate
    }
}

/// 素材的固有属性。
///
/// **不需要解码就能拿到**——这正是它和 `CGImage` 分开的原因：LOD 选档位要先用
/// 到原图尺寸，而为了知道尺寸去解码一次，等于把"避免解码"的优化自己抵消掉。
/// 真实实现走 ImageIO 的元数据读取（不触发像素解码）。
///
/// `pixelSize` 是**方向已校正**的尺寸：EXIF 旋转在链路上只处理一次，
/// 到这里就是"摆正之后"的尺寸。批次 C 导入 HEIC 时方向是必测项
/// （路线图 §5），把它收在这一处，渲染器就不用再关心。
struct ImageMetadata: Equatable, Sendable {
    let pixelSize: CGSize
}

/// 一次图片请求的结果。
///
/// ## 为什么把"没有"和"坏了"分开
///
/// 两者给用户的信息不同：**素材没了**是"这张图被移除了"（引用还在，原图不在），
/// **解码失败**是"这个文件坏了"。路线图 §5 要求"损坏数据保留备份与诊断，
/// 不静默覆盖"，而区分二者的前提是链路上没有把它们合并成一个 `nil`。
///
/// 批次 B 的合成素材不会失败，所以这两个分支现在只有断言在走。留着是因为
/// `MaterialSourceContent` 那次的教训：失败分支**第一版不写，批次 C 就一定会
/// 以"先当成功处理"起步**，而表现是画面安静地空着，最难查。
enum ImageRequestResult: Sendable {
    case image(CGImage)
    /// 素材不存在。ID 有效，但库里查无此物。
    case missing
    /// 素材存在但取不到像素，附原因。
    case failed(String)
    /// 请求方取消了这个请求，**在解码开始之前**（B2 的取消）。
    ///
    /// ## 为什么单独一个分支，而不是复用 `failed`
    ///
    /// 两者对用户的意义相反：失败要**报出来**（"这张图坏了"），取消恰恰是
    /// "别再做了"——把它记成失败，画布上会冒出一批并无其事的错误。
    ///
    /// ## 边界（诚实口径）
    ///
    /// 取消只在**解码开始前**成立。一旦进了 `CGContext` 的填充循环，就没法
    /// 从外面打断它——C 层没有中断点。所以已经跑起来的解码会跑完、结果照常
    /// 入缓存（活已经干了，丢掉才是浪费），但**不会写进图层**：那是渲染器
    /// 侧负责的，见 `LayerRenderer` 的代次与 `Task.isCancelled` 双重判据。
    case cancelled
}

/// 图片内容从哪来：渲染器与素材面板拿像素的**唯一**入口。
///
/// ## 为什么必须有这一层
///
/// `CanvasElement` 存的是 `AssetID`（元素只引用素材、不拥有它），所以渲染器
/// 需要一条把 `AssetID` 变成像素的路。批次 C 的素材库还没建，但这条**接口**
/// 不能等到那时才定——接口晚一步到位，第一批实现就会绕开它：渲染器会自己
/// 长出解码与缓存，批次 C 再想共成就得把渲染器拆开。
///
/// ## 为什么缓存不在渲染器里（协议上不出现，但由实现负责）
///
/// 三件事都会真的出错：
///
/// 1. **素材面板和画布必须共用一份。** 各缓存一份的话，同一张图在面板和画布上
///    各解码一遍，内存翻倍。`MaterialItem` 刻意不带已解码图片就是为了这个
///    （`Materials/MaterialProvider.swift`），这里把它落成真的。
/// 2. **切画布不该清空。** 缓存按**素材**存，不按元素、也不按画布——同一张图
///    在两块画布上是同一个缓存条目。（B1 的调试快捷键会验证这一点。）
/// 3. **预算要有单一出口。** 只有一处知道总共占了多少字节，才谈得上淘汰。
///
/// ## 约定
///
/// - `@MainActor`，与 `MaterialProvider` 一致。**缓存簿记在主线程，解码不在**：
///   实现方自己负责把 CPU 密集那部分放到非隔离的执行器上去。
///   主线程做 `layer.contents = image` 之外的事，路线图 §2.4 的
///   「主线程 P95 < 8ms」就守不住。
/// - 失败**不抛错**：写成 `.missing` / `.failed(原因)`。抛错的话每个调用点都要
///   接一层 `try`，而"失败了画什么"本来就是渲染的一部分。
/// - 两个方法都必须**可重入**：同一个素材会被并发的多个请求同时问到
///   （画布元素 + 面板缩略图），实现要保证不会重复解码同一档位。
@MainActor
protocol ImageProvider: AnyObject {
    /// 读素材属性。素材不存在时返回 `nil`。
    func metadata(for asset: AssetID) async -> ImageMetadata?

    /// 取指定档位的像素。
    ///
    /// - Parameter targetPixelSize: 解码目标尺寸。实现应当把它归到自己的一档上
    ///   （见 `LODTier`），而不是按传入的精确尺寸缓存——否则缓存键会随缩放漂移。
    ///
    /// ## 调用方传的必须是"已经定下来的那一档"
    ///
    /// 这条约定容易被写反，写反了还不容易发现，所以写在这里：实现**会**拿传入的
    /// 尺寸再判一次档（归到自己的一档上），而调用方（渲染器）自己那次判档带着
    /// 迟滞（`LODTier.settled`）。于是传原始需求就等于**把选档权让给了实现**：
    /// 渲染器决定"这一档先不降"，实现却按"刚好覆盖需求"又降了一级，结果是
    /// 记账与像素不一致——画面只是糊一点，肉眼看不出来。
    ///
    /// 所以调用方传 `LODTier.pixelSize(forOriginal:)` 的结果。那一档的尺寸本来就
    /// 落在自己的档上，实现这边的归并是恒等变换，两边的判断从此一致。
    func image(for asset: AssetID, targetPixelSize: CGSize) async -> ImageRequestResult
}
