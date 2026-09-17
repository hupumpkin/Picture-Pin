import Foundation
import Observation

/// 工作台状态。SwiftUI 侧唯一的可变真源。
///
/// ## 画布相关的一切都在 `boards` 里
///
/// 场景、相机、选择都是**每块画布各一份**，不再是这个类型上的三个字段。
/// 为什么：这三样加多画布时都得变成复数，而它们已经同时被工具栏、宿主视图、
/// 快照工具和自检依赖——等到那时再改就是一次波及全部调用点的结构改动。
/// 收进 `BoardStore` 之后，加多画布是加界面和加持久化，不是改结构。
///
/// 下面那三个转发属性是为了让调用点读起来仍然是"当前画布的场景/相机/选择"——
/// 它们没有自己的存储，只是 `boards` 的视图。
@MainActor
@Observable
final class WorkspaceModel {

    let environment: AppEnvironment

    /// 全部画布与当前画布。本轮只有一块（路线图 §6），但集合是真的。
    let boards: BoardStore

    /// 当前画布的场景。批次 A 不插入任何元素；批次 B/C 的导入会经命令通道改它。
    var scene: CanvasScene { boards.activeScene }

    /// 当前画布的相机。`CanvasHostView` 的直接操控与工具栏按钮都改这一个值。
    var camera: CanvasCamera {
        get { boards.activeCamera }
        set { boards.activeCamera = newValue }
    }

    /// 当前画布选中的元素。选择逻辑属于 Codex 的 `SelectionController`，
    /// 这里只持有结果供覆盖层与工具栏读取。
    var selection: Set<CanvasElementID> { boards.activeSelection }

    var motionConfiguration: MotionConfiguration

    /// 数据目录准备失败的原因。非空时界面必须显示出来。
    ///
    /// 第一版用 `try?` 吞掉了这个错误。空画布阶段看不出问题，但进入导入与保存后
    /// 它的表现是「界面一切正常、数据不落盘」——那时再查要绕很大一圈。
    private(set) var storageError: String?

    /// 工具栏命令通道。由 `CanvasHostView` 在挂载时填入实现。
    let commands = CanvasCommandRelay()

    /// 像素管线的唯一实例。
    ///
    /// **由模型持有，向下注入渲染器**，理由和 `materialSources` 一样：它是
    /// 一份共享资源，不是渲染器的私人物品。画布元素和素材面板缩略图必须走
    /// 同一个实例，否则同一张图解码两遍，缩放时内存翻倍。
    ///
    /// B1 是合成提供者（`SyntheticImageProvider`）：像素程序生成，不读磁盘。
    /// 批次 C 换成读素材库的实现时，**这里换一个构造，其余一行不用动**。
    let images: any ImageProvider

    /// 像素的共享缓存。**单独持有**，因为它不只被提供者用：
    ///
    /// - 内存压力要能找到它（`MemoryPressureMonitor` 直接调 `handle(_:)`）；
    /// - B2 的报告要读它的账面（峰值、命中率、淘汰次数）。
    ///
    /// 留在提供者内部的话，这两件事都得多穿一层协议——而"只有一处知道总共占了
    /// 多少字节"这个前提（见 `ImageCache`）要求它有一个明确的持有者。
    let imageCache: ImageCache

    /// 合成素材目录。B1 阶段它同时是"演示内容的来源"——
    /// 详见 `SyntheticImageProvider.makeAssets(count:)`。
    let syntheticAssets: [SyntheticImageProvider.Asset]

    /// 左侧素材面板是否展开。
    var isMaterialPanelVisible = true

    /// 本轮注册的素材来源。
    ///
    /// **由 `environment` 建出来，不是全局常量**：素材读取要用数据目录，而目录按
    /// profile 不同。视图不再自己去查目录表，只读这一个值——这样"来源列表"
    /// 只有一个真源，批次 C 的真实提供者也有地方拿目录。
    let materialSources: [MaterialSource]

    /// 当前选中的来源。
    var activeSourceID: MaterialSourceID

    /// 当前来源。**非空保证**：`materialSources` 至少一条（见 `make(environment:)`）。
    var activeSource: MaterialSource {
        source(activeSourceID) ?? materialSources[0]
    }

    func source(_ id: MaterialSourceID) -> MaterialSource? {
        materialSources.first { $0.id == id }
    }

    init(
        environment: AppEnvironment = .resolve(),
        boards: BoardStore = BoardStore(),
        syntheticAssetCount: Int = 12,
        imageCache: ImageCache = ImageCache()
    ) {
        self.environment = environment
        self.boards = boards
        self.motionConfiguration = .default
        // 素材表先建出来，再拿它建提供者——提供者不自己生成素材，
        // 这样"画布上有哪些图"和"演示场景往画布上放哪些图"是同一份数据。
        let assets = SyntheticImageProvider.makeAssets(count: syntheticAssetCount)
        self.syntheticAssets = assets
        self.imageCache = imageCache
        self.images = SyntheticImageProvider(assets: assets, cache: imageCache)
        // 先建列表再选默认来源：`activeSourceID` 不能指向一个不存在的来源。
        let sources = MaterialSourceCatalog.make(environment: environment)
        self.materialSources = sources
        self.activeSourceID = sources[0].id
    }

    /// 缩放百分比的显示文本。
    var zoomPercentText: String {
        "\(Int((camera.zoom * 100).rounded()))%"
    }

    /// 窗口尺寸变化后由 `CanvasHostView` 回报。
    func updateViewport(size: CGSize) {
        boards.updateViewport(size: size)
    }

    /// 画布宿主改过场景后回写。宿主是直接操控期间的权威版本，这里只跟着走。
    func applyScene(fromCanvas scene: CanvasScene) {
        boards.applyScene(scene)
    }

    func applySelection(fromCanvas selection: Set<CanvasElementID>) {
        boards.applySelection(selection, for: boards.activeBoardID)
    }

    /// 建立数据目录结构。可重试——失败原因会显示在界面上。
    func prepareStorage() {
        do {
            try environment.prepareDirectories()
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
    }
}
