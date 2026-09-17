import AppKit
import QuartzCore

/// CALayer 渲染器（路线图 §2.1 主方案）。
///
/// ## 图层结构
///
/// ```text
/// hostLayer（宿主视图的 backing layer，坐标系 = view）
///   ├── worldLayer      相机变换作用在这里，所有元素图层是它的子层
///   │     └── （元素图层，批次 B 接入）
///   └── overlayLayer    屏幕空间覆盖层：选择框、手柄、辅助线
/// ```
///
/// 相机变化只更新 `worldLayer` 的变换，元素图层的像素原样复用。
///
/// ## 边界（路线图 §2.1 明确要求写清楚）
///
/// 「只改一个矩阵」**不是整个应用零开销的保证**。以下情况仍会产生解码、
/// 图层更新或重绘：LOD 跨档、元素进入视口、图片内容变更。批次 B 的实测报告
/// 要按这个口径记录，不能把图层提交耗时说成帧时间。
///
/// 批次 A 建立图层树、相机通道，以及元素图层的**生命周期**（建、改、删、重排）。
/// 图层的 `contents` 是空的——图片解码、LOD、缓存属于批次 B。
@MainActor
final class LayerRenderer: CanvasRenderer {

    /// 相机变换作用的根层。
    let worldLayer = CALayer()
    /// 屏幕空间覆盖层，不参与相机变换。
    let overlayLayer = CALayer()

    /// 像素从哪来。**没有默认值**：默认值会让"忘了接线"编译通过，
    /// 而表现是画布上什么都不显示——正是这个项目反复踩的那类问题。
    private let images: any ImageProvider

    private var configuration: MotionConfiguration
    private var backingScaleFactor: CGFloat = 2

    /// 相机。**改它就会重算档位**——这是唯一的写入口。
    ///
    /// ## 为什么重算挂在这里，而不是挂在"渲染增量"那条路上
    ///
    /// 第一版挂在 `apply(_:)` 里（`update.camera != nil` 时重算），因为当时
    /// 以为相机只会从那条路进来。实际上**捏合、⌘+滚轮、拖拽、工具条的缓动**
    /// 都是直接写 `context.camera`（见 `MinimalInputAdapter`），根本不经过
    /// `apply`。于是放大之后矩阵更新了、画面却停在低清档——**独立复审报回来的
    /// 就是这个**。读代码看不出来：写相机的那几处看起来都很正常。
    ///
    /// 挂在属性上，这类路径就不必各自记得调用一次；漏掉一处就是"某个手势特别糊"。
    var camera: CanvasCamera {
        get { storedCamera }
        set { adoptCamera(newValue, recomputeTiers: true) }
    }

    private var storedCamera: CanvasCamera

    /// 相机状态的唯一落点。
    ///
    /// `recomputeTiers` 为 `false` 时只更新矩阵——**只有 `apply` 用它**：
    /// 那一条自己会在所有图层都改完之后统一重算一次，而它开头的这次赋值发生在
    /// 元素外框更新**之前**，这时重算会用旧外框算出中间那一档，白跑一次解码。
    private func adoptCamera(_ newCamera: CanvasCamera, recomputeTiers: Bool) {
        guard newCamera != storedCamera else { return }
        storedCamera = newCamera
        applyCameraToWorldLayer()
        if recomputeTiers { refreshVisibleContent() }
    }

    init(
        camera: CanvasCamera = .identity,
        configuration: MotionConfiguration = .default,
        images: any ImageProvider
    ) {
        self.storedCamera = camera
        self.configuration = configuration
        self.images = images

        worldLayer.anchorPoint = .zero
        worldLayer.position = .zero
        worldLayer.masksToBounds = false
        // 隐式动画会让相机变化产生拖尾——路线图 §2.3 要求显式区分直接操控与
        // 程序动画，所以这里彻底关掉隐式动画，动画一律由显式路径驱动。
        worldLayer.actions = Self.animationsDisabled

        overlayLayer.anchorPoint = .zero
        overlayLayer.position = .zero
        overlayLayer.masksToBounds = false
        overlayLayer.actions = Self.animationsDisabled

        applyCameraToWorldLayer()
    }

    /// 把图层挂到宿主视图的 backing layer 上。
    func attach(to hostLayer: CALayer) {
        guard worldLayer.superlayer !== hostLayer else { return }
        hostLayer.addSublayer(worldLayer)
        hostLayer.addSublayer(overlayLayer)
        updateLayerFrames(for: camera.viewportSize)
    }

    func setMotionConfiguration(_ configuration: MotionConfiguration) {
        self.configuration = configuration
    }

    func setBackingScaleFactor(_ scale: CGFloat) {
        guard scale != backingScaleFactor else { return }
        backingScaleFactor = scale
        worldLayer.contentsScale = scale
        overlayLayer.contentsScale = scale
        // 已建好的元素图层要一起跟上：换到高密度屏时旧图层若停在 1×，
        // 图片内容会糊，而这只在换显示器时才看得出来。
        for layer in elementLayers.values {
            layer.contentsScale = scale
        }
        // 光改 `contentsScale` 只是把同一份像素放大画——**需要多少像素本身变了**，
        // 档位得重算。这是我的自查发现的：独立复审报的是相机那一条，而"像素需求"
        // 一共有三个来源（外框、缩放、屏幕倍率），当时只有外框和缩放接了线。
        refreshVisibleContent()
    }

    /// 视口尺寸变化时同步图层几何。相机的 `viewportSize` 由宿主维护，
    /// 这里只跟随。
    func updateLayerFrames(for viewportSize: CGSize) {
        let bounds = CGRect(origin: .zero, size: viewportSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if worldLayer.bounds.size != viewportSize {
            worldLayer.bounds = bounds
            overlayLayer.bounds = bounds
        }
        PerformanceProbe.measure("commit.geometry") { CATransaction.commit() }
        applyCameraToWorldLayer()
        // 这里**不重算档位**：需要多少像素是「外框 × 缩放 × 屏幕倍率」，
        // 视口尺寸不在其中——视口变大只是看得见的东西变多，元素的屏幕尺寸不变。
        // 第一版这里有一句 `refreshImageTiers()`，注释写的是"视口变大 = 元素在
        // 屏幕上变大"，那句话是错的（它是把"窗口变大"当成了"缩放变大"），
        // 那行代码因此从来没有改变过任何一个档位。三者各自的触发点是：
        // 外框 → `updateElements`，缩放 → `camera` 的 setter，倍率 → 本类的
        // `setBackingScaleFactor`。
        //
        // **但它要重算可见性**（B2 的视口虚拟化）：视口尺寸不在"需要多少像素"
        // 里，却在"**哪些元素看得见**"里，而后者决定谁该有图层。
        // 两件事容易混成一件，区别就在这句话上。
        refreshVisibleContent()
    }

    func apply(_ update: CanvasRenderUpdate) {
        guard !update.isEmpty else { return }

        // 只更新矩阵，档位留到最后统一重算一次：此刻元素外框还没更新，
        // 这时重算会拿旧外框算出一个中间档位，白跑一次解码。
        if let camera = update.camera {
            adoptCamera(camera, recomputeTiers: false)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 顺序：先删后插再改，最后统一重排。先删是必须的——同一个 id 在
        // removed 和 inserted 里同时出现时（换画布场景），先删才不会留下孤儿图层。
        if let removed = nonEmpty(update.removed) {
            removeElements(removed)
        }
        if let inserted = nonEmpty(update.inserted) {
            insertElements(inserted)
        }
        if let updated = nonEmpty(update.updated) {
            updateElements(updated)
        }
        if let overlay = update.overlay {
            lastOverlay = overlay
        }
        applyOrder(update.order)
        // 图层的建与删不在这里逐条做，统一交给 refreshVisibleContent()——
        // 它同时决定可见性、几何与档位，是这三件事的唯一出口。
        syncSublayerOrder()

        PerformanceProbe.measure("commit") { CATransaction.commit() }

        // 场景或相机变了就重算一次。`overlay` 单独的更新（选择变化）不走这里：
        // 它不改几何也不改相机，重算纯属白扫一遍元素。
        //
        // 这次重算是给开头那次 `recomputeTiers: false` 收尾的：元素外框此时
        // 已经更新，重算才是对的。
        let sceneChanged = !update.inserted.isEmpty
            || !update.updated.isEmpty
            || !update.removed.isEmpty
        if update.camera != nil || sceneChanged {
            refreshVisibleContent()
        }
    }

    /// 最近一次收到的覆盖层描述。
    ///
    /// 批次 A 只把它**收下**，不绘制：选择框与手柄的画法要和选择模型一起定，
    /// 那是批次 C 的事（路线图 §3.2）。先存下来是为了让覆盖层通道有可断言的
    /// 终点——「通道通了但没人接线」和「通道不通」在自检里必须能区分开。
    private(set) var lastOverlay: CanvasOverlay = .empty

    // MARK: - 相机

    /// 相机 → `worldLayer` 变换。
    ///
    /// 世界点 `w` 映射到视图点：`(w - center) * zoom + viewportSize / 2`，
    /// 与 `CanvasCamera.worldToView` 完全一致——两处必须保持同一个公式，
    /// 否则命中与显示会错位。
    private func applyCameraToWorldLayer() {
        let transform = CATransform3D(
            m11: camera.zoom, m12: 0, m13: 0, m14: 0,
            m21: 0, m22: camera.zoom, m23: 0, m24: 0,
            m31: 0, m32: 0, m33: 1, m34: 0,
            m41: -camera.center.x * camera.zoom + camera.viewportSize.width / 2,
            m42: -camera.center.y * camera.zoom + camera.viewportSize.height / 2,
            m43: 0, m44: 1
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        worldLayer.transform = transform
        // 单独记名：平移的每一帧走的就是这一条，混进"commit"那个桶里会让
        // 报告里的"每次提交耗时"变成两个不同量级的东西的平均值。
        PerformanceProbe.measure("commit.camera") { CATransaction.commit() }
    }

    // MARK: - 元素图层
    //
    // 批次 B 起图层的 `contents` 承载真图片。像素一律走 `ImageProvider`：
    // 渲染器不自己解码、也不自己缓存（见 `ImageProvider` 里"为什么缓存不在
    // 渲染器里"那一段）。
    //
    // ## 场景里的元素 ≠ 有图层的元素（B2 的视口虚拟化）
    //
    // 1000 个元素全都建图层、全都解码，是这个批次最直接的内存与时间开销来源，
    // 而**屏幕外的元素一个像素都看不见**。所以分成两层：
    //
    // - `elementModels` —— 渲染器知道的**全部**元素（场景的镜像），一直在；
    // - `elementLayers` —— 只含**可见区域 + 预加载边距**内、真正建了图层的那些。
    //
    // 进出可见区域是**可逆**的：移出去的丢掉图层与在飞的请求，移回来重新建。
    // 像素不用重新解码——它还在共享缓存里（`ImageCache` 按素材 × 档位存，
    // 不按元素）。这正是"移出视口再移回"这条必测场景（路线图 §5）的判据。

    /// id → 元素图层。**只含当前可见的**；`worldLayer.sublayers` 是渲染结果，
    /// 这里是唯一的持有者。
    private var elementLayers: [CanvasElementID: CALayer] = [:]
    /// id → 元素模型。**含全部元素**，包括不可见的。
    ///
    /// 留着不可见元素的模型有两个用处：换档时要按外框重算需要多少像素
    /// （`CanvasRenderUpdate` 只给变化的部分，攒不出来）；以及判断"它是不是
    /// 又回到可见区域了"——把这个判断交给场景去问，等于每帧都要遍历场景。
    private var elementModels: [CanvasElementID: CanvasElement] = [:]
    /// 最近一次算出的可见世界矩形（含预加载边距）。自检读它。
    private(set) var visibleWorldRect: CGRect = .null
    /// 当前建了图层的元素数。**这是虚拟化的效果本身**，报告里要记。
    var materializedElementCount: Int { elementLayers.count }

    // MARK: 图片请求的状态
    //
    // 这四张表合起来解决同一个问题：**异步结果回来时，世界可能已经变了。**

    /// 素材原始像素尺寸。取过一次就留着——换档判断是同步的，不能每次都 await。
    private var assetPixelSizes: [AssetID: CGSize] = [:]
    /// 已经确认不存在的素材。单独一张表，免得每次相机变化都重新去问一遍。
    private var missingAssets: Set<AssetID> = []
    /// 每个元素当前**已经显示出来**的是哪张素材的哪一档。
    ///
    /// 两样都要记。只记档位是独立复审报回来的缺陷：档位是"多少像素"，
    /// 素材是"哪张图"——同一个元素换了素材而档位没变时（换图、换版本、
    /// 重新导入同一张图的新副本都会这样），只比档位就会判定"没变化"，
    /// 于是**画面继续显示旧图**，而所有记账看起来都是对的。
    private struct DisplayedImage: Equatable {
        var asset: AssetID
        var tier: LODTier
    }

    /// 档位和素材都没变就不发请求，这是缩放时不产生重复解码的关键。
    private var displayed: [CanvasElementID: DisplayedImage] = [:]
    /// 每个元素的图片请求代次。
    ///
    /// 只要元素被更新、被移除、或档位变了，代次就 +1；异步回来的结果代次对不上
    /// 就丢弃。没有这个的话，快速连续缩放时会有好几个解码同时在飞，先发的后到，
    /// **画面会退回旧档位**——用户看到的是"越缩放越糊"。
    private var imageGeneration: [CanvasElementID: UInt64] = [:]
    /// 每个元素**在飞的那次请求**。取消它有两个好处：还没开始的解码不再开始
    /// （省下整张 4K 的时间），以及移出可见区域的元素不再占用一个待写的图层。
    private var imageTasks: [CanvasElementID: Task<Void, Never>] = [:]
    /// 正在飞的元数据请求，按素材合并。同一张图在画布上出现三次只问一次。
    private var pendingMetadata: Set<AssetID> = []

    /// 取不到像素的元素及原因。批次 B 没有画布上的错误提示（元素级错误 UI 属于
    /// 批次 C），但**不能什么都不留**：失败被静默吞掉的表现是画布安静地空着，
    /// 和"还没解码完"长得一模一样。自检读它。
    private(set) var imageFailures: [CanvasElementID: String] = [:]
    /// 期望的绘制顺序（由下到上）。由场景同步与新插入的图层共同维护，
    /// 是 `worldLayer.sublayers` 的目标状态。
    ///
    /// 单独存一份而不是直接读 `sublayers`：`apply` 允许只给 `inserted` 不给 `order`
    /// （增量语义不要求调用方每次都带全序），那时不能把新图层随手 append 到末尾。
    private var drawOrder: [CanvasElementID] = []

    // MARK: - 可见性与档位（唯一的入口）

    /// 重新评估**哪些元素该有图层**，以及**每个该用哪一档**。
    ///
    /// 这是场景结构、相机、视口、屏幕倍率四条路径的共同终点——四个地方各写一遍
    /// "遍历元素"的话，迟早有一条路径漏掉虚拟化或漏掉迟滞，而表现分别是"某些
    /// 元素永远不显示"和"某些手势特别糊"，都属于读代码看不出来的那类。
    ///
    /// ## 开销
    ///
    /// 一次 O(元素数) 的线性扫描，且**每一次相机写入都会走一遍**（包括拖拽平移
    /// 的每一帧，因为平移也是写相机）。元素在 O(10³) 量级时这是几十微秒量级，
    /// 与 §2.4 的 8ms 预算差两个数量级；真到了不够用的时候，下一步是把
    /// `elementModels` 换成按外框建索引（四叉树 / 网格），而不是省掉这次扫描。
    ///
    /// ## 为什么"重算档位"和"筛选可见"写在同一个函数里
    ///
    /// 因为它们**用的是同一个矩形**：不可见的元素根本不需要正确档位，而可见性
    /// 又是"外框 × 相机"决定的。分成两处就得算两遍可见矩形，也就有了两处可能
    /// 用不同的边距。
    private func refreshVisibleContent() {
        let rect = camera.visibleWorldRect(preloadMargin: configuration.viewport.preloadMargin)
        visibleWorldRect = rect

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 埋点包住的是**这一遍扫描**（可见性 + 档位 + 请求发出），不含提交：
        // 报告里要把"每帧主线程工作"拆成扫描与提交两块，混在一起就没法定位了。
        let materializationChanged = PerformanceProbe.measure("scan") { () -> Bool in
            var changed = false
            for (id, element) in elementModels {
                if element.frame.intersects(rect) {
                    if materialize(id, element) { changed = true }
                    if let layer = elementLayers[id] {
                        requestImage(for: element, layer: layer)
                    }
                } else if dematerialize(id) {
                    changed = true
                }
            }
            return changed
        }
        if materializationChanged { syncSublayerOrder() }
        PerformanceProbe.measure("commit") { CATransaction.commit() }
    }

    /// 确保这个元素有图层，并让它的几何跟场景走。返回**是否新建了图层**。
    @discardableResult
    private func materialize(_ id: CanvasElementID, _ element: CanvasElement) -> Bool {
        if let layer = elementLayers[id] {
            layer.frame = element.frame
            return false
        }
        elementLayers[id] = makeLayer(for: element)
        PerformanceProbe.count("materialize")
        return true
    }

    /// 丢掉这个元素的图层与在飞的请求。返回**是否真的丢掉了东西**。
    ///
    /// 刻意**不动共享缓存**：那张图还在缓存里，移回来的时候直接命中，
    /// 不必重新解码。缓存腾不腾是预算的事（`ImageCache`），不是可见性的事——
    /// 让可见性顺手去清缓存，等于把"缩放到别处看一眼"变成一次全量重解码。
    @discardableResult
    private func dematerialize(_ id: CanvasElementID) -> Bool {
        // 计数放在 `guard` **之后**：这个函数对每一个"当前不在视口里"的元素都会被
        // 调用一次，而其中绝大多数本来就没有图层。数在 guard 之前的话，
        // 报告里的"丢层次数"会变成"扫描到多少个屏幕外元素"——1000 元素、
        // 400 帧的场景下它报的是 39 万次，而真实丢层只有几十次。
        // 这类数字看着很像"发现了性能问题"，实际上是量错了地方。
        imageTasks.removeValue(forKey: id)?.cancel()
        guard let layer = elementLayers.removeValue(forKey: id) else { return false }
        PerformanceProbe.count("dematerialize")
        layer.removeFromSuperlayer()
        // 代次作废：已经飞出去的那次解码回来时代次对不上，会被丢掉。
        // 少了这一句，它会照样把像素写进一个已经不在树上的图层——看不见，
        // 但白占内存，而且元素移回来时会先看到上一次的过期档。
        imageGeneration.removeValue(forKey: id)
        displayed.removeValue(forKey: id)
        imageFailures.removeValue(forKey: id)
        return true
    }

    /// 场景给了新元素。**只记模型**，图层的建与删交给 `refreshVisibleContent()`。
    private func insertElements(_ elements: [CanvasElement]) {
        for element in elements where elementModels[element.id] == nil {
            elementModels[element.id] = element
            drawOrder.append(element.id)
        }
    }

    /// 场景改了元素。只记模型（外框会在 `materialize` 里落到图层上）。
    private func updateElements(_ elements: [CanvasElement]) {
        for element in elements {
            if elementModels[element.id] == nil {
                elementModels[element.id] = element
                drawOrder.append(element.id)
            } else {
                elementModels[element.id] = element
            }
        }
    }

    private func removeElements(_ ids: [CanvasElementID]) {
        for id in ids {
            dematerialize(id)
            elementModels.removeValue(forKey: id)
        }
        let target = Set(ids)
        drawOrder.removeAll { target.contains($0) }
    }

    /// 应用新的绘制顺序。为 `nil` 表示顺序未变，但新插入的图层可能还没进过
    /// `drawOrder` 的目标序列——那种情况交给 `syncSublayerOrder` 从字典补齐。
    ///
    /// 按 `elementModels` 而不是 `elementLayers` 过滤：绘制顺序是**场景**的属性，
    /// 与当前可见不可见无关。用图层字典过滤的话，一个元素滑出视口再回来就会
    /// 掉到最上面——那是虚拟化直接制造出来的错。
    private func applyOrder(_ order: [CanvasElementID]?) {
        guard let order else { return }
        drawOrder = order.filter { elementModels[$0] != nil }
    }

    /// 把 `worldLayer.sublayers` 对齐到 `drawOrder`。
    ///
    /// 用整表赋值而不是逐个 `insertSublayer(at:)`：后者在下标随插入变化时很容易
    /// 错位，而且一次赋值就是一次事务内的批量操作。先比一遍是为了避免每帧都
    /// 重建子层数组——相机平移会走 `apply`，那条路径上不该有重排开销。
    private func syncSublayerOrder() {
        let ordered = drawOrder.compactMap { elementLayers[$0] }
        let current = worldLayer.sublayers ?? []
        guard current.count != ordered.count
                || !zip(current, ordered).allSatisfy({ $0 === $1 })
        else { return }
        worldLayer.sublayers = ordered
    }

    private func makeLayer(for element: CanvasElement) -> CALayer {
        let layer = CALayer()
        // 隐式动画必须显式关掉：默认的 0.25 秒 position/bounds 过渡会让拖拽
        // 变成"追光标"，看起来像手感发黏，实际是图层在插值。批次 A 用临时参照
        // 图形实测过这一条，详见 HANDOFF。
        layer.actions = Self.animationsDisabled
        layer.contentsScale = backingScaleFactor
        layer.frame = element.frame
        // 占位底色**保留**，但作用变了：它不再代表"这里有个元素"（那由真图负责），
        // 而是**首图就绪之前的顶替**。
        //
        // 为什么不干脆空着：元素第一次出现时没有旧图可留，空着就是一帧白。
        // 路线图 §2.3 的「禁止空白闪烁」在两种情况下要求不一样——**已有元素换档**
        // 靠保留旧图（本文件 `requestImage`），**元素首次出现**只能靠占位。
        // 顺带它也是带透明通道图片的底，所以图片到了之后也不清掉。
        layer.backgroundColor = Self.placeholderColor
        return layer
    }

    private static let placeholderColor = NSColor.secondaryLabelColor
        .withAlphaComponent(0.16).cgColor

    // MARK: - 图片
    //
    // 可见性与档位的统一入口在 `refreshVisibleContent()`（上面「可见性与档位」一节）。

    /// 元素当前需要多少像素：屏幕显示尺寸 × backingScaleFactor。
    private func targetPixelSize(for element: CanvasElement) -> CGSize {
        CGSize(
            width: max(1, element.frame.width * camera.zoom * backingScaleFactor),
            height: max(1, element.frame.height * camera.zoom * backingScaleFactor)
        )
    }

    private func requestImage(for element: CanvasElement, layer: CALayer) {
        guard case .image(let asset) = element.kind else { return }
        let id = element.id

        if missingAssets.contains(asset) {
            imageFailures[id] = "素材不存在"
            return
        }
        guard let original = assetPixelSizes[asset] else {
            loadMetadata(for: asset)
            return
        }

        let target = targetPixelSize(for: element)
        // **带迟滞**的选档（B2）。`from:` 传的是"当前已经显示（或已经发出请求）的
        // 那一档"——去掉这个参数就退回 B1 的行为：需求一跨过边界就换档，
        // 于是在边界上来回缩放会反复解码。见 `LODTier.settled`。
        let tier = LODTier.settled(
            target,
            original: original,
            from: displayed[id]?.tier,
            headroom: configuration.lod.downgradeHeadroom
        )
        // **素材和档位都没变**才是"屏幕上该显示的东西没变"。这里直接返回是缩放时
        // 不重复解码的全部秘密；少了这一句，每帧都会发一次请求。只比档位则会让
        // 换素材之后继续显示旧图（见 `DisplayedImage`）。
        let wanted = DisplayedImage(asset: asset, tier: tier)
        guard displayed[id] != wanted else { return }
        displayed[id] = wanted
        PerformanceProbe.count("tierChange")
        PerformanceProbe.count("imageRequest")

        let generation = (imageGeneration[id] ?? 0) + 1
        imageGeneration[id] = generation

        // 上一次请求作废。**取消是真的**：如果它还没开始解码，提供者看到
        // `Task.isCancelled` 就不会启动（省下的是整张 4K 的解码时间，不是一点点）；
        // 已经进了 `CGContext` 的那次拦不住，靠下面的代次判据丢掉结果。
        imageTasks.removeValue(forKey: id)?.cancel()
        // 请求里传的是**已经定下来的那一档**的像素尺寸，不是上面那个原始需求
        // （`target`）。这一条是自检逼出来的：提供者会拿传入的尺寸**再判一次档**
        // （`ImageProvider` 的约定），而它用的是没有迟滞的 `fitting`。传原始需求
        // 的话，渲染器这边迟滞判对了档、提供者那边又把它降回"刚好覆盖需求"的那一
        // 档——**记账说 1 档，图层里是 2 档的像素**。画面只是比预期糊一点，肉眼
        // 看不出来（自检是比像素尺寸才发现的），但迟滞等于白做：每跨一次边界照样
        // 解一张新图，只是解得更糊。
        let requestedSize = tier.pixelSize(forOriginal: original)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.images.image(for: asset, targetPixelSize: requestedSize)
            // 两道判据缺一不可：
            // - `Task.isCancelled`：这个元素被移出可见区域、或者又换了一档——
            //   这次的结果**连缓存都不该影响**（提供者那边已经按取消处理）。
            // - 代次：结果回来时世界可能已经变了。迟到的旧档结果覆盖新档，
            //   就是"缩放时画面忽然变糊"。
            guard !Task.isCancelled, self.imageGeneration[id] == generation else { return }
            switch result {
            case .image(let image):
                layer.contents = image
                self.imageFailures[id] = nil
            case .missing:
                self.imageFailures[id] = "素材不存在"
            case .failed(let reason):
                self.imageFailures[id] = reason
            case .cancelled:
                // 取消不是失败，什么都不记（见 `ImageRequestResult.cancelled`）。
                break
            }
        }
        imageTasks[id] = task
    }

    /// 元素外框要用到原图比例（导入时按原图尺寸定外框），所以尺寸必须先拿到。
    /// 按素材合并请求：同一张图在画布上出现多次只问一遍。
    private func loadMetadata(for asset: AssetID) {
        guard !pendingMetadata.contains(asset) else { return }
        pendingMetadata.insert(asset)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let metadata = await self.images.metadata(for: asset)
            self.pendingMetadata.remove(asset)
            if let metadata {
                self.assetPixelSizes[asset] = metadata.pixelSize
            } else {
                self.missingAssets.insert(asset)
            }
            // 尺寸到手（或确认没有）之后重走一遍，这条路径上的元素才算接上。
            // 走的是同一个入口：这里也要筛可见性——元数据回来时可能有元素
            // 已经移出视口了，那它不该被"顺手"建出图层来。
            self.refreshVisibleContent()
        }
    }

    private func nonEmpty<T>(_ array: [T]) -> [T]? {
        array.isEmpty ? nil : array
    }

    // MARK: - 自检用的图层查询
    //
    // 这几个入口不属于 `CanvasRenderer` 协议，只服务 `--selftest` 的
    // 「场景 → 渲染器 → 图层」闭环断言：断言必须读**真实的图层树**，
    // 读渲染器自己的字典等于自证。

    /// `worldLayer` 里实际的子层对应的元素 id，由下到上。
    var sublayerIDsInDrawOrder: [CanvasElementID] {
        let owners = Dictionary(
            elementLayers.map { (ObjectIdentifier($0.value), $0.key) },
            uniquingKeysWith: { first, _ in first }
        )
        return (worldLayer.sublayers ?? []).compactMap { owners[ObjectIdentifier($0)] }
    }

    /// 某个元素图层的实际外框。
    func sublayerFrame(of id: CanvasElementID) -> CGRect? {
        elementLayers[id]?.frame
    }

    /// 某个元素图层当前承载的像素尺寸。还没解码完时返回 `nil`。
    ///
    /// 读的是 **`layer.contents` 本身**，不是渲染器记的账。这一条很关键：
    /// 断言要证明"图片真的进了图层"，读自己的记账等于自证。
    func sublayerImageSize(of id: CanvasElementID) -> CGSize? {
        // 类型判断走 `CFGetTypeID`，不走 `as?`：CoreFoundation 类型从 `Any`
        // 做条件转换会被编译器判成"永远成功"（`as?` 和 `as AnyObject as?` 都是），
        // 那就等于没判。类型 ID 是 CF 自己的判法，能真的挡住"图层里放的是
        // 别的东西"（比如以后有人放了 `NSImage`）。
        guard let contents = elementLayers[id]?.contents,
              CFGetTypeID(contents as CFTypeRef) == CGImage.typeID
        else { return nil }
        let image = unsafeDowncast(contents as AnyObject, to: CGImage.self)
        return CGSize(width: image.width, height: image.height)
    }

    /// 某个元素当前显示的是哪一档。
    func sublayerTier(of id: CanvasElementID) -> LODTier? { displayed[id]?.tier }

    private static let animationsDisabled: [String: CAAction] = [
        "position": NSNull(),
        "bounds": NSNull(),
        "transform": NSNull(),
        "contents": NSNull(),
        "opacity": NSNull(),
        "hidden": NSNull(),
    ]
}
