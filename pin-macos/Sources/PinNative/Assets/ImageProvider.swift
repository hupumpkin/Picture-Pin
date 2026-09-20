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
    /// ## 解码上限（§3.9 第 3 条）
    ///
    /// 结果**永远不会比 `DecodePolicy.maximumTier(forOriginal:)` 更细**：
    /// 200 MP 的图允许入库，但全档永远不解——上限收在阶梯本身，渲染器
    /// （选档）与提供者（解码）共用同一个 `fitting`，两边的口径天然一致。
    /// 要是在解码前临时夹一刀，就会出现"记账说是这一档、像素其实是更粗
    /// 那一档"的错账。
    ///
    /// - Parameters:
    ///   - required: 当前显示实际需要多少像素（显示尺寸 × backingScaleFactor）。
    ///   - original: 原图像素尺寸。**必须由元数据提供，不能先解码再量**——
    ///     如果为了知道尺寸而解码一次，选档位这件事本身就没有意义了。
    ///   - policy: 解码上限。默认是 §3.9 定的值；自检注入小上限来实测这条规则。
    static func fitting(
        _ required: CGSize,
        original: CGSize,
        policy: DecodePolicy = DecodePolicy()
    ) -> LODTier {
        // 上限先算：参数不合法时的兜底档位也必须是它——返回 `.full` 会让一张
        // 超限的图回到"全档解码"，正是上限要挡的事。
        let cap = policy.maximumTier(forOriginal: original)
        guard required.width > 0, required.height > 0,
              original.width > 0, original.height > 0
        else { return cap }

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
        let tier = LODTier(level: level)
        // `level` 越小档越细；比上限细就退回上限那一档。
        return tier.level < cap.level ? cap : tier
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
    /// 解码上限（§3.9 第 3 条）在此一并生效：`demanded` 经 `fitting` 已被上限
    /// 夹过，迟滞走出的结果（从 `current` 出发只会更粗，但 `current` 理论上
    /// 可能细于上限）在返回前也再夹一次——阶梯的产物**永远不会越过上限**。
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
        headroom: CGFloat,
        policy: DecodePolicy = DecodePolicy()
    ) -> LODTier {
        let cap = policy.maximumTier(forOriginal: original)
        let demanded = fitting(required, original: original, policy: policy)
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
        return candidate.level < cap.level ? cap : candidate
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

/// 一个**磁盘上的图片文件**的属性。导入时读它，此时素材还没入库、还没有 `AssetID`。
///
/// ## 为什么不能直接用 `ImageMetadata`
///
/// 因为它比 `ImageMetadata` 多一样东西：`ImageMetadata` 是**渲染器要的**（"这张图
/// 该按什么比例摆"），而方向已经被消化掉了。导入要的是**文件里写着什么**——
/// 方向值要原样存进库，这样"我们把它摆成了什么样"和"文件里写的是什么"两件事
/// 都留了痕。方向解析错了的时候，只有原始值能把它们对上（路线图 §5 把 EXIF
/// 列为必测项，而必测项没留原始值就等于没有证据）。
struct ImageFileFacts: Equatable, Sendable {
    /// **摆正之后**的像素尺寸（与 `ImageMetadata.pixelSize` 同一口径）。
    let pixelSize: CGSize
    /// 文件里写着的 EXIF 方向值。1 = 不旋转；没有 EXIF 时按 1 记。
    let exifOrientation: Int
}

/// 探一个**还没入库的文件**。读不出来返回 `nil`（不是能解码的图片、文件损坏）。
///
/// 与 `ImageProvider` 分开是因为问的问题不同：那个问"这个素材的像素在哪"，
/// 这个问"这个文件是什么"。实现是同一个（`FileImageProvider`），但它不该
/// 因此被塞进渲染器要看的那个协议里——渲染路径不需要、也不该有"文件"这个概念。
@MainActor
protocol ImageFileProbing: AnyObject {
    func probe(_ url: URL) async -> ImageFileFacts?
}

/// `AssetID` → 磁盘位置。
///
/// ## 为什么是一个协议，而不是让提供者去查库
///
/// **解码路径上不允许出现数据库查询。** 这条路每次扫描都会被走到（见
/// `LayerRenderer.requestImage`），而一次查询就是一次 I/O——主线程预算（§2.4）
/// 会在"画布上有一百个元素"时当场破掉。所以查库只发生在启动那一次，结果装进
/// 一个字典（`SnapshotAssetLocator`），解码路径上只有一次字典查找。
@MainActor
protocol AssetFileLocator: AnyObject {
    func fileURL(for asset: AssetID) -> URL?
}

/// 已经在内存里的一张图，以及它是哪一档。
///
/// 两个都要：图层要拿它当 `contents`，而渲染器记账时要知道**它到底是哪一档**
/// ——记错档的后果是下一次扫描以为"屏幕上已经是目标档了"，于是永远不去要
/// 那张该要的图，画面一直糊着。
struct CachedImage: Sendable {
    let image: CGImage
    let tier: LODTier
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
    /// 像素驻留账本。**渲染器往它申报"图层拿了哪一档"，实现（缓存）读它决定淘汰。**
    ///
    /// 为什么走协议暴露而不是各自 new 一个：账本一旦有两份，"图层的持有"和
    /// "缓存的淘汰"就各看各的表，而症状是"预算看着正常、内存一直涨"——正是
    /// 独立复审报回来的缺陷 ③。挂在提供者上，二者在结构上就是同一个实例，
    /// 想接错也接不出来。
    var residency: ImageResidency { get }

    /// 读素材属性。素材不存在时返回 `nil`。
    func metadata(for asset: AssetID) async -> ImageMetadata?

    /// 同步取一张**已经在内存里**的、不比 `tier` 更细的图。没有就返回 `nil`。
    ///
    /// **绝不允许在这里解码**：它在一次同步的可见性扫描里被调用，解码会让
    /// §2.4 的主线程预算当场破掉。它的用途只有一个——§3.9 第 1 条的代价那一半：
    /// 元素拖回视口时先贴一张已经在内存里的小图（先糊一下），再等目标档。
    func cachedImage(for asset: AssetID, atMost tier: LODTier) -> CachedImage?

    /// 这个素材已经**离开视口**：放掉它没人拿着的高档位，只留一张便宜的。
    ///
    /// §3.9 第 1 条的触发点。**只有渲染器知道"它出去了"**，所以由它调用；
    /// 留哪一档、留多大，是实现（缓存）的事。
    ///
    /// 为什么不是"任何一次持有归零都放"：从场景里删掉的元素（换画布）走的是
    /// 另一条路——缓存按素材共享、与画布无关，顺手放掉的后果是换一次画布把
    /// 所有图重新解码一遍。这两件事在调用点上是分开的，在实现里也就分得开。
    func releaseOffscreenPixels(of asset: AssetID)

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
