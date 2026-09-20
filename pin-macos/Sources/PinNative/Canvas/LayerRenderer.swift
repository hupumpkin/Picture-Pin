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

    /// 覆盖层的三块画布。见 `init` 里为什么是三块。
    private let selectionBorderLayer = CAShapeLayer()
    private let selectionHandleLayer = CAShapeLayer()
    private let marqueeLayer = CAShapeLayer()

    /// 像素从哪来。**没有默认值**：默认值会让"忘了接线"编译通过，
    /// 而表现是画布上什么都不显示——正是这个项目反复踩的那类问题。
    private let images: any ImageProvider

    /// 失败之后的重试节奏。可注入是给自检用的（把 0.5/1/2 秒压成毫秒级）。
    private let retryPolicy: ImageRetryPolicy

    private var configuration: MotionConfiguration
    private var backingScaleFactor: CGFloat = 2

    /// 覆盖层配色所依据的外观。宿主在视图外观变化时更新它。
    ///
    /// 覆盖层的颜色是 **CALayer 上的静态 CGColor**，图层不会自己跟着系统
    /// 深浅色变——不显式重取的话，用户在深色模式下选中一张图，描边还是浅色
    /// 模式那一版。宿主在 `viewDidChangeEffectiveAppearance` 里写这个属性。
    var appearance: NSAppearance = NSAppearance.currentDrawing() {
        didSet { refreshAppearance() }
    }

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
        images: any ImageProvider,
        retryPolicy: ImageRetryPolicy = .default
    ) {
        self.storedCamera = camera
        self.configuration = configuration
        self.images = images
        self.retryPolicy = retryPolicy

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

        // 覆盖层分三层，因为一个 CAShapeLayer 只有一套描边参数：
        // 选中框是实线、框选是虚线 + 半透明填充、手柄是"白底 + 描边"的方块，
        // 三者放一层里就得互相将就。
        selectionBorderLayer.fillColor = nil
        selectionBorderLayer.lineWidth = SelectionGeometry.borderWidth
        selectionHandleLayer.lineWidth = 1
        marqueeLayer.lineWidth = 1
        marqueeLayer.lineDashPattern = SelectionGeometry.marqueeDash.map { NSNumber(value: $0) }
        for layer in [selectionBorderLayer, selectionHandleLayer, marqueeLayer] {
            layer.anchorPoint = .zero
            layer.position = .zero
            layer.actions = Self.animationsDisabled
            overlayLayer.addSublayer(layer)
        }
        applyOverlayColors()

        applyCameraToWorldLayer()
    }

    /// 把图层挂到宿主视图的 backing layer 上。
    func attach(to hostLayer: CALayer) {
        guard worldLayer.superlayer !== hostLayer else { return }
        hostLayer.addSublayer(worldLayer)
        hostLayer.addSublayer(overlayLayer)
        updateLayerFrames(for: camera.viewportSize)
    }

    /// 换一套参数。
    ///
    /// ## 为什么不能只赋值（独立复审报回来的缺陷）
    ///
    /// `viewport.preloadMargin` 变了就是"可见区"变了，`lod.downgradeHeadroom` 变了
    /// 就是"该用哪一档"变了——两者都只在下一次 `refreshVisibleContent()` 时才生效，
    /// 而那个函数只在相机写入与解码完成时被调用。于是**运行时把边距从 0 调到 400
    /// 什么都不会发生**，直到用户碰一下画布。开发调参窗口（路线图 §3.3）正是靠这个
    /// 接口，它调不动就等于那个窗口是假的。
    ///
    /// 只在真的影响可见性或档位时才重算：手感参数（缓动曲线、`feel`）改了不必
    /// 走一遍 O(元素数) 的扫描。
    func setMotionConfiguration(_ configuration: MotionConfiguration) {
        let affectsVisibility = configuration.viewport != self.configuration.viewport
            || configuration.lod != self.configuration.lod
        self.configuration = configuration
        guard affectsVisibility else { return }
        refreshVisibleContent()
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
            renderOverlay()
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
    /// 存下来有两个用途：**重画**（相机一变就要按新投影重画一遍，描述本身
    /// 不动）和**自检的断言终点**。「通道通了但没人接线」和「通道不通」在
    /// 自检里必须能区分开——所以除了这一份描述，还有 `renderedSelectionBorderCount`
    /// / `renderedHandleCount` / `renderedMarqueeVisible` 三个从**真实路径**
    /// 反读出来的探针。
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
        // 覆盖层是世界坐标描述的，投影到视图点是相机的事——所以相机一变就得重画。
        // 覆盖层描述本身没变（`lastOverlay` 不动），变的只是它落在屏幕上的位置。
        renderOverlay()
    }

    // MARK: - 覆盖层绘制（选择框、手柄、框选）
    //
    // 位置用世界坐标给、尺寸按视图点算（`CanvasOverlay` 的约定），
    // 所以这里的每一步都是"世界 → 视图"的投影，没有第二套几何。
    // 手柄的边长与命中区定义在 `SelectionGeometry`——画和点是同一组常量。

    /// 覆盖层里现在有几个描边矩形。自检读它——"通道通了但没人画"和"画了"
    /// 在断言里必须能区分开。
    var renderedSelectionBorderCount: Int {
        guard let path = selectionBorderLayer.path, !path.isEmpty else { return 0 }
        return lastOverlay.selectionFrames.count
    }

    /// 手柄路径里现在有几个方块（真实几何，不是记账）。
    var renderedHandleCount: Int {
        guard let path = selectionHandleLayer.path else { return 0 }
        // 每个手柄是一个圆角矩形子路径：数 "move to" 的个数。
        var count = 0
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { count += 1 }
        }
        return count
    }

    /// 框选矩形现在画没画。
    var renderedMarqueeVisible: Bool { !(marqueeLayer.path?.isEmpty ?? true) }

    /// 选中框在**视图坐标**里的位置。
    ///
    /// 覆盖层的描述是世界坐标，落到屏幕上的位置只有相机知道——这条探针钉的是
    /// "相机一变，覆盖层跟着重投影"。少了那一步的表现是：拖动元素时选中框
    /// 跟着走，但一平移画布，选中框就停在原地（而元素已经移开了）。
    var renderedSelectionBorderBounds: CGRect {
        selectionBorderLayer.path?.boundingBox ?? .null
    }

    private func renderOverlay() {
        let camera = storedCamera
        let border = CGMutablePath()
        for frame in lastOverlay.selectionFrames {
            border.addRect(camera.worldToView(frame))
        }
        selectionBorderLayer.path = border

        let handles = CGMutablePath()
        if let frame = lastOverlay.handleFrame {
            let side = SelectionGeometry.handleSize
            for (_, center) in SelectionGeometry.handleCenters(of: frame, camera: camera) {
                let rect = CGRect(
                    x: center.x - side / 2,
                    y: center.y - side / 2,
                    width: side,
                    height: side
                )
                handles.addRoundedRect(in: rect, cornerWidth: 1.5, cornerHeight: 1.5)
            }
        }
        selectionHandleLayer.path = handles

        let marquee = CGMutablePath()
        if let rect = lastOverlay.marquee {
            marquee.addRect(camera.worldToView(rect))
        }
        marqueeLayer.path = marquee
    }

    /// 覆盖层的颜色。
    ///
    /// 与元素图层的占位色不同，覆盖层是**常驻**的：不跟着外观重算的话，
    /// 用户在深色模式里选中一个元素，看到的会是浅色模式那份描边——
    /// 一片深灰上的浅灰线，几乎不可见。宿主在 `viewDidChangeEffectiveAppearance`
    /// 里会调 `refreshAppearance()`。
    private func applyOverlayColors() {
        let palette = CanvasPalette.current
        selectionBorderLayer.strokeColor = resolved(palette.selectionBorder)
        selectionHandleLayer.fillColor = resolved(palette.handleFill)
        selectionHandleLayer.strokeColor = resolved(palette.selectionBorder)
        marqueeLayer.strokeColor = resolved(palette.marqueeBorder)
        marqueeLayer.fillColor = resolved(palette.marqueeFill)
    }

    /// 动态色（跟随外观）在**写进 CALayer 的那一刻**就要定下用哪一版——
    /// `CGColor` 是一次性的快照，不像 `NSColor` 会自己跟着外观变。
    private func resolved(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        appearance.performAsCurrentDrawingAppearance {
            result = color.cgColor
        }
        return result
    }

    /// 外观切换（深浅色）后重取覆盖层颜色。宿主在
    /// `viewDidChangeEffectiveAppearance` 里调一次。
    func refreshAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyOverlayColors()
        CATransaction.commit()
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

    /// **图层里真的已经有**的那张素材的那一档。只在像素到达时才写。
    ///
    /// ## 它和 `requested` 为什么要分开（独立复审报回来的缺陷）
    ///
    /// B2 只有这一张表，而且在**发出请求时**就写进去了。那等于宣布"屏幕上已经是
    /// 这张图了"，于是请求失败时它仍然成立：下一次扫描走到"档位和素材都没变就
    /// 不发请求"那一句直接返回，**这个元素再也不会重试**，一直空着。合成素材
    /// 不会失败，所以只有断言走得到这条路径；真实文件会（外置卷、权限、
    /// 文件被占用）。
    ///
    /// 分开之后两张表各管一件事，判据也就各归各的：
    /// - `displayed` —— 已经在屏幕上的。**它没变就说明不用重新解码**（缩放的
    ///   性能靠这一条）；
    /// - `requested` —— 已经在路上、还没回来的。它挡住的是"同一次需求重复发车"。
    private var displayed: [CanvasElementID: DisplayedImage] = [:]

    /// 已经发出去、还没回来的那次需求。结果回来（成功、失败、缺失）就清掉。
    ///
    /// 「清掉」是关键：清掉之后下一次扫描会重新走到发请求那一句——**重试因此
    /// 是免费的**，不必另写一条"重新请求"的路径。真正的闸门是下面的退避时间，
    /// 不是这张表。
    private var requested: [CanvasElementID: DisplayedImage] = [:]

    /// 失败之后的重试记账。
    private struct RetryState: Equatable {
        /// 已经安排过几次自动重试。
        var attempts: Int
        /// 下一次允许自动重试的时间点。`attempts` 到顶时是 `.distantFuture`
        /// ——"不再自动重试"和"还没到点"在请求那一侧是同一个判断。
        var nextAttemptAt: Date
        /// 这次失败的是**哪张素材的哪一档**。
        ///
        /// 需求换了一个（用户放大了、换了图）就是另一个请求，退避从头算：不然
        /// 用户放大之后要等上一次失败的退避走完才看得到新档位。
        var failed: DisplayedImage
    }

    private var retryStates: [CanvasElementID: RetryState] = [:]
    /// 每个元素那个"睡一会儿再回来看"的任务。元素被移出可见区域时要能取消掉，
    /// 否则它到点后会把一个屏幕外的元素重新拉进扫描。
    private var retryTasks: [CanvasElementID: Task<Void, Never>] = [:]

    /// 每个元素的图层**正拿着**哪一档的像素。
    ///
    /// 两件事都靠它（缺陷 ③ 与 §3.9 第 1 条）：
    /// - 申报给 `images.residency`——预算不算图层持有的像素就守不住；
    /// - 放手时让缓存知道"这一档已经没人看了"，它才敢把高档位放掉。
    ///
    /// **只有渲染器知道这件事**：图层是它建的，`contents` 是它写的。
    private var layerHolds: [CanvasElementID: ImageResidency.Key] = [:]

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
                } else if dematerialize(id, leftViewport: true) {
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
    /// - Parameter leftViewport: 是因为**滚出可见区域**（`true`）还是因为
    ///   **从场景里被删掉**（`false`）。两者的区别只有一处，但很关键：
    ///
    ///   滚出去的，按 §3.9 第 1 条把它的高档位放掉（这正是那一条的触发点）；
    ///   从场景里删掉的**不放**——那条路走的是换画布，而缓存按素材共享、
    ///   与画布无关（`ImageProvider` 里写死的一条）。顺手放掉的后果是**换一次
    ///   画布把所有图重新解码一遍**，正是"切画布卡一下"的来源。
    ///
    ///   B2 的自检当场就抓到了这一点：`boardSwitchKeepsDecodedImages` 红了。
    @discardableResult
    private func dematerialize(_ id: CanvasElementID, leftViewport: Bool = false) -> Bool {
        // 计数放在 `guard` **之后**：这个函数对每一个"当前不在视口里"的元素都会被
        // 调用一次，而其中绝大多数本来就没有图层。数在 guard 之前的话，
        // 报告里的"丢层次数"会变成"扫描到多少个屏幕外元素"——1000 元素、
        // 400 帧的场景下它报的是 39 万次，而真实丢层只有几十次。
        // 这类数字看着很像"发现了性能问题"，实际上是量错了地方。
        imageTasks.removeValue(forKey: id)?.cancel()
        guard let layer = elementLayers.removeValue(forKey: id) else { return false }
        PerformanceProbe.count("dematerialize")
        // **放手要先于丢图层**：账本里"这个图层还拿着哪一档"必须跟着图层一起
        // 消失。反过来的话，图层已经不在树上了、账本却还记着它拿着——那些全尺寸
        // 像素就再也没人认领，也再没人放掉（缓存看到"有人拿着"，一档都不会省）。
        //
        // 账本自己**不做决定**：它只记事实。"这个素材已经没人看了、可以放掉
        // 高档位"这件事由下面那一句显式说出来，而不是从"持有归零"里推出来——
        // 推出来的话，"为什么这张图忽然要重解码"就成了一条看不见的因果链。
        releaseLayerHold(id)
        // §3.9 第 1 条：滚出可见区域的元素不留全尺寸。**账本先放手、再放像素**——
        // 顺序反了的话，缓存看到的还是"有人拿着"，一档都不会放。
        //
        // 换画布那条路（`leftViewport == false`）不走这一句：缓存按素材共享，
        // 与画布无关。见本函数的参数说明。
        if leftViewport, case .image(let asset) = elementModels[id]?.kind {
            images.releaseOffscreenPixels(of: asset)
        }
        layer.removeFromSuperlayer()
        // 代次作废：已经飞出去的那次解码回来时代次对不上，会被丢掉。
        // 少了这一句，它会照样把像素写进一个已经不在树上的图层——看不见，
        // 但白占内存，而且元素移回来时会先看到上一次的过期档。
        imageGeneration.removeValue(forKey: id)
        displayed.removeValue(forKey: id)
        imageFailures.removeValue(forKey: id)
        // 重试记账一起清。留着的话，元素移回来时退避时间还没过就会被挡住——
        // "拖出去再拖回来不显示"是虚拟化直接制造出来的错。
        //
        // 刻意**不**清 `missingAssets`：那是素材级的判断（文件真的不在），
        // 与可见性无关。清它的地方只有一个——手动重新加载。
        requested.removeValue(forKey: id)
        retryTasks.removeValue(forKey: id)?.cancel()
        retryStates.removeValue(forKey: id)
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
            // `leftViewport: false`：这是"从场景里删掉"（含换画布），不是滚出去。
            // 两者在这里必须分开——见 `dematerialize` 的参数说明。
            dematerialize(id, leftViewport: false)
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
        // 占位底色只服务**首图就绪之前**那一小段：元素第一次出现时没有旧图可留，
        // 空着就是一帧白。路线图 §2.3 的「禁止空白闪烁」在两种情况下要求不一样
        // ——**已有元素换档**靠保留旧图（本文件 `requestImage`），**元素第一次
        // 出现**只能靠占位。
        //
        // **真图一到就撤掉**（`finish`）：它不再是带透明通道图片的底。垫着它的
        // 话，透明区域透出来的是这块灰——产品负责人实测反馈过"透明 PNG 显示成
        // 灰块"，那句旧注释（"图片到了之后也不清掉"）就是它的出处。
        layer.backgroundColor = Self.placeholderColor
        return layer
    }

    private static let placeholderColor = NSColor.secondaryLabelColor
        .withAlphaComponent(0.16).cgColor

    /// 取不到像素时的底色。
    ///
    /// 用**降透明度的红**而不是纯红：它要能在一屏图片里被一眼认出来，又不能红到
    /// 抢走画面本身的注意力。走系统色而不是写死的 RGB——深色模式与"增强对比度"
    /// 辅助功能会各自调整它，写死的颜色在这两种情况下都要重新调一遍。
    ///
    /// 这是 C1 里**唯一**的元素级错误反馈：失败的元素必须一眼和"还没解码完"
    /// 区分开。两者都表现为"这块地方没有图"，而后者几毫秒后就会好。
    private static let failedPlaceholderColor = NSColor.systemRed
        .withAlphaComponent(0.18).cgColor

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

    // MARK: - 驻留记账
    //
    // 缺陷 ③：缓存预算不算图层持有的像素，而图层持有的恰恰是"看得见的那些"
    // ——全尺寸、最贵的一批。申报给账本，预算才是真的预算。

    /// 申报：这个图层开始铺这一档的像素。
    ///
    /// 字节数在这里算（渲染器是第一个拿到 `CGImage` 的人）。同一素材同一档
    /// 被两个图层铺时，账本只记一份——它们拿的是同一个对象。
    private func holdLayer(_ id: CanvasElementID, asset: AssetID, tier: LODTier, image: CGImage) {
        releaseLayerHold(id)
        let key = ImageResidency.Key(asset: asset, tier: tier)
        images.residency.hold(key, bytes: ImageResidency.byteCost(of: image))
        layerHolds[id] = key
    }

    /// 申报：这个图层不再铺那一档了。
    ///
    /// 最后一句"没人拿了"是**缓存淘汰顺序**的依据（先丢没人拿的），但这一句
    /// 本身不触发任何像素的释放——那件事由 `dematerialize` 在明确的位置说出口。
    private func releaseLayerHold(_ id: CanvasElementID) {
        guard let key = layerHolds.removeValue(forKey: id) else { return }
        images.residency.release(key)
    }

    private func requestImage(for element: CanvasElement, layer: CALayer) {
        guard case .image(let asset) = element.kind else { return }
        let id = element.id

        if missingAssets.contains(asset) {
            imageFailures[id] = "素材不存在"
            // 底色也要跟着变：恢复出来的画布上如果有个元素的原图被删了，
            // 它必须一眼就是"坏的"，而不是一个看起来正常、其实永远空着的灰块。
            layer.backgroundColor = Self.failedPlaceholderColor
            return
        }
        guard let original = assetPixelSizes[asset] else {
            loadMetadata(for: asset)
            return
        }

        let target = targetPixelSize(for: element)
        // **带迟滞**的选档（B2）。`from:` 传的是"当前已经显示、或已经发出请求的
        // 那一档"——去掉这个参数就退回 B1 的行为：需求一跨过边界就换档，
        // 于是在边界上来回缩放会反复解码。见 `LODTier.settled`。
        //
        // 在飞的那次优先：它比 `displayed` 更接近"用户现在想要什么"。只看
        // `displayed` 的话，一次降级请求还在路上时需求又被算作"从高档降下来"，
        // 迟滞会朝反方向多走一步。
        let tier = LODTier.settled(
            target,
            original: original,
            from: (requested[id] ?? displayed[id])?.tier,
            headroom: configuration.lod.downgradeHeadroom
        )
        // **素材和档位都没变**才是"屏幕上该显示的东西没变"。这里直接返回是缩放时
        // 不重复解码的全部秘密；少了这一句，每帧都会发一次请求。只比档位则会让
        // 换素材之后继续显示旧图（见 `DisplayedImage`）。
        let wanted = DisplayedImage(asset: asset, tier: tier)

        // 拖回视口时**先贴一张已经在内存里的小图**（§3.9 第 1 条的代价那一半）。
        //
        // 元素离开视口时，它那一档的高清像素已经被放掉了（`demoteUnheldTiers`）。
        // 不贴的话，拖回来的一瞬间是空的——"先糊一下再变清晰"是产品负责人确认过
        // 的代价，"先空一下"不是。这里只是把**已经在内存里**的那张铺上去，
        // 不解码，所以它不违反主线程预算。
        //
        // 只在"什么都没有"时贴：已经有了像素的元素不该被一张糊的盖掉。
        if displayed[id] == nil, let seed = images.cachedImage(for: asset, atMost: tier) {
            layer.contents = seed.image
            // 贴上去的是**真像素**（小档位），所以和 `finish` 同一口径：不留底色，
            // 免得带透明通道的素材先糊成一块灰再"变透明"。
            layer.backgroundColor = nil
            holdLayer(id, asset: asset, tier: seed.tier, image: seed.image)
            displayed[id] = DisplayedImage(asset: asset, tier: seed.tier)
            PerformanceProbe.count("imageSeeded")
        }
        guard displayed[id] != wanted else { return }
        // 同一次需求只发一趟车。
        guard requested[id] != wanted else { return }
        // 这一趟是不是还在退避里。**需求换了就是另一个请求**，退避从头算——
        // 不然用户放大之后要等上一次失败的退避走完才看得到新档位。
        if let state = retryStates[id], state.failed == wanted {
            guard Date() >= state.nextAttemptAt else { return }
        } else {
            retryStates[id] = nil
        }
        requested[id] = wanted
        PerformanceProbe.count("tierChange")
        PerformanceProbe.count("imageRequest")
        startRequest(
            for: element, layer: layer, asset: asset,
            wanted: wanted, original: original, tier: tier
        )
    }

    /// 把一次请求真的发出去。
    ///
    /// 从 `requestImage` 里拆出来是因为**发车的入口有两个**（常规扫描与退避到点），
    /// 而"两个入口各写一遍发车逻辑"正是这个文件反复吃亏的那种结构：迟滞、代次、
    /// 取消三件事只要有一处写法不一样，表现就是"某些元素偶尔退回旧档"。
    private func startRequest(
        for element: CanvasElement,
        layer: CALayer,
        asset: AssetID,
        wanted: DisplayedImage,
        original: CGSize,
        tier: LODTier
    ) {
        let id = element.id
        let generation = (imageGeneration[id] ?? 0) + 1
        imageGeneration[id] = generation

        // 上一次请求作废。**取消是真的**：如果它还没开始解码，提供者看到
        // `Task.isCancelled` 就不会启动（省下的是整张 4K 的解码时间，不是一点点）；
        // 已经进了 `CGContext` 的那次拦不住，靠下面的代次判据丢掉结果。
        imageTasks.removeValue(forKey: id)?.cancel()
        // 请求里传的是**已经定下来的那一档**的像素尺寸，不是上面那个原始需求
        // （`target`）。这一条是自检逼出来的：提供者会拿传入的尺寸**再判一次档**
        // （`ImageProvider` 的约定），而它用的是没有迟滞的 `fitting`。传原始需求
        // 的话，渲染器这边迟滞判对了档、提供者那边又把它降回"刚好覆盖需求"的那
        // 一档——**记账说 1 档，图层里是 2 档的像素**。画面只是比预期糊一点，肉眼
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
            self.finish(result, for: id, layer: layer, asset: asset, wanted: wanted)
        }
        imageTasks[id] = task
    }

    /// 一次请求的结果落到世界上。
    private func finish(_ result: ImageRequestResult, for id: CanvasElementID, layer: CALayer, asset: AssetID, wanted: DisplayedImage) {
        switch result {
        case .image(let image):
            // 先放手旧的、再申报新的：反过来的话，两档之间会短暂地"同一素材
            // 被拿着两档"，缓存那边的"已经没人看了"就永远不会成立。
            layer.contents = image
            holdLayer(id, asset: asset, tier: wanted.tier, image: image)
            // **底色整块撤掉**，不是"换回占位色"。CALayer 的底色画在 `contents`
            // 后面，图片的透明区域会把它透出来——垫着它，带透明通道的 PNG 在
            // 画布上就是"一张图带个灰底"（产品负责人实测反馈的正是这个）。
            // 撤掉之后透明区域透出的是画布本身，这才是"透明"该有的样子。
            //
            // 失败态不吃这一句：`recordFailure` 会自己把底色染红，那条路径
            // 要的恰恰是"这块地方一眼就是坏的"。
            layer.backgroundColor = nil
            imageFailures[id] = nil
            retryStates[id] = nil
            retryTasks.removeValue(forKey: id)?.cancel()
            requested[id] = nil
            // `displayed` 只在这里写——**像素到了才算显示出来了**。这是这项
            // 缺陷修复的全部要点，写在别处就会退回"失败后永远不再重试"。
            displayed[id] = wanted
        case .missing:
            // 文件真的不在：记进 `missingAssets`，自动重试不再去问磁盘。
            // 卷不会在几秒内挂上来，而手动入口正是为"我已经把它放回来了"准备的。
            missingAssets.insert(asset)
            recordFailure(for: id, wanted: wanted, reason: "素材不存在", layer: layer, automaticRetry: false)
        case .failed(let reason):
            recordFailure(for: id, wanted: wanted, reason: reason, layer: layer, automaticRetry: true)
        case .cancelled:
            // 取消不是失败，什么都不记（见 `ImageRequestResult.cancelled`）。
            break
        }
    }

    /// 一次请求以失败收场：记账、染上失败底色，并安排自动重试。
    ///
    /// - Parameter automaticRetry: `false` 用于"素材不存在"。文件真的不在时，
    ///   退避重试只是在替用户反复问一个已经知道答案的问题；手动入口才是为
    ///   "我已经把文件放回来了"准备的那条路。
    private func recordFailure(
        for id: CanvasElementID,
        wanted: DisplayedImage,
        reason: String,
        layer: CALayer,
        automaticRetry: Bool
    ) {
        imageFailures[id] = reason
        // **请求结束了**。清掉之后下一次扫描会重新走到发请求那一句，能不能真发
        // 由退避决定——重试因此是免费的，不必另写一条"重新请求"的路径。
        requested[id] = nil
        layer.backgroundColor = Self.failedPlaceholderColor
        guard automaticRetry else { return }
        scheduleAutomaticRetry(for: id, wanted: wanted)
    }

    /// 安排下一次自动重试。
    ///
    /// 到顶之后**不安排**，只把状态写成 `.distantFuture`：自动重试到此为止，
    /// 剩下的路是手动（元素上的失败底色 + 工具栏的重新加载）。为什么不无限重试
    /// 见 `ImageRetryPolicy`。
    private func scheduleAutomaticRetry(for id: CanvasElementID, wanted: DisplayedImage) {
        let attempts = (retryStates[id]?.attempts ?? 0) + 1
        guard attempts <= retryPolicy.maximumAutomaticRetries else {
            retryStates[id] = RetryState(
                attempts: attempts,
                nextAttemptAt: .distantFuture,
                failed: wanted
            )
            PerformanceProbe.count("imageRetryExhausted")
            return
        }
        let delay = retryPolicy.delay(beforeAttempt: attempts)
        retryStates[id] = RetryState(
            attempts: attempts,
            nextAttemptAt: Date().addingTimeInterval(delay),
            failed: wanted
        )
        PerformanceProbe.count("imageRetryScheduled")

        retryTasks.removeValue(forKey: id)?.cancel()
        retryTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.retryTasks[id] = nil
            // 到点后**不直接重发请求**，而是走那个统一入口：元素这时可能已经
            // 移出视口（那就不该重试）、已经被删掉、也可能已经手动重新加载过。
            // 自己发请求的话，这三件事都要各写一遍判断。
            self.refreshVisibleContent()
        }
    }

    // MARK: - 手动重新加载
    //
    // 产品负责人定的口径（`BATCH_C_TASK.md` §7 第 9 条）：**自动退避重试与手动
    // 入口两条都要**。自动那条解决"过一会儿自己就好了"；手动这条解决"我已经把
    // 文件放回来了 / 卷挂上了 / 权限给了"——后者等多久都不会自己好。

    /// 当前取不到像素的元素。界面靠它决定显不显示"重新加载"入口。
    var failedImageIDs: Set<CanvasElementID> {
        Set(imageFailures.keys.filter { elementModels[$0] != nil })
    }

    /// 重新加载某个元素的图片。
    ///
    /// **每个失败的都要能单独重试**，不只是"全部重来一次"：一屏里两张坏图时，
    /// 用户想重试的往往是刚修好的那一张。
    func retryImage(for id: CanvasElementID) {
        guard elementModels[id] != nil else { return }
        PerformanceProbe.count("imageRetryManual")
        clearFailure(for: id)
        refreshVisibleContent()
    }

    /// 重新加载**所有**取不到像素的元素。返回这次重试了几个——没有失败时是 0，
    /// 界面靠它决定要不要出现这个入口。
    @discardableResult
    func retryAllFailedImages() -> Int {
        let ids = failedImageIDs
        guard !ids.isEmpty else { return 0 }
        PerformanceProbe.count("imageRetryManual", by: ids.count)
        for id in ids { clearFailure(for: id) }
        refreshVisibleContent()
        return ids.count
    }

    /// 清掉一个元素的失败记账。
    ///
    /// 与自动路径的区别只有一处，但很关键：**`missingAssets` 也清**。
    /// 那是"这张素材不存在"的记忆，自动重试留着它才不会每隔几秒去问一次磁盘；
    /// 而手动点一下的含义恰恰是"再去看一眼"。
    private func clearFailure(for id: CanvasElementID) {
        imageFailures.removeValue(forKey: id)
        retryStates.removeValue(forKey: id)
        retryTasks.removeValue(forKey: id)?.cancel()
        requested.removeValue(forKey: id)
        if case .image(let asset) = elementModels[id]?.kind {
            missingAssets.remove(asset)
        }
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

    /// 这个元素现在铺的是**失败底色**吗。
    ///
    /// 断言它而不是断言"渲染器记了失败"：用户看到的只有颜色。底色的取值逻辑
    /// 以后可以改（换色、加深色模式差异），"失败的元素必须与'还没加载完'
    /// 长得不一样"这条判据不能改。
    func sublayerShowsFailurePlaceholder(of id: CanvasElementID) -> Bool {
        elementLayers[id]?.backgroundColor == Self.failedPlaceholderColor
    }

    /// 这个元素图层现在有没有底色（占位色与失败色都算）。
    ///
    /// 与"是不是失败色"分开问，是因为**真图到位之后底色应当整块撤掉**：
    /// 只要还剩任何一种底色，带透明通道的素材在画布上就自带一个底。
    /// 断言这个布尔值而不是断言"等于某个具体颜色"：颜色的取值以后可以改，
    /// "透明区域前面不许垫东西"这条判据不能改。
    func sublayerHasBackingColor(of id: CanvasElementID) -> Bool {
        elementLayers[id]?.backgroundColor != nil
    }

    /// 某个元素**图层里真的有**的是哪一档的像素。还没等到像素时是 `nil`。
    ///
    /// B2 时这里返回的是"已经发出请求的那一档"——因为当时 `displayed` 在发请求
    /// 时就写了。分开之后它的含义变成字面意思：**图上已经是这一档**。要问"请求
    /// 发了没有"用 `requestedTier(of:)`。
    func sublayerTier(of id: CanvasElementID) -> LODTier? { displayed[id]?.tier }

    /// 某个元素**正在要**（在飞）或已经显示的那一档。
    ///
    /// 与 `sublayerTier` 的差别就是"在飞的那段时间"：迟到、失败、被取消的请求
    /// 都只影响 `sublayerTier`。断言问"请求发出去了吗"用这个。
    func requestedTier(of id: CanvasElementID) -> LODTier? {
        (requested[id] ?? displayed[id])?.tier
    }

    /// 还在等像素（或等重试）的元素。断言用它区分"失败"与"正在来"。
    func isAwaitingImage(_ id: CanvasElementID) -> Bool {
        requested[id] != nil || retryStates[id] != nil
    }

    private static let animationsDisabled: [String: CAAction] = [
        "position": NSNull(),
        "bounds": NSNull(),
        "transform": NSNull(),
        "contents": NSNull(),
        "opacity": NSNull(),
        "hidden": NSNull(),
    ]
}
