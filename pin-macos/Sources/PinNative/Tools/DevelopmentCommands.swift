#if DEBUG
import AppKit
import CoreGraphics
import Foundation

/// 开发构建专用的调试入口。
///
/// ## 为什么这些必须存在，而不是"顺手加的便利功能"
///
/// 产品行为是**从空白画布开始**（路线图 §6：原生版从全新空库开始，不读任何旧数据）。
/// 所以画布上不会自己长出内容——批次 B 把图片管线接通之后，「图片到底显示得对不对、
/// 缩放时档位换得对不对」这两件事**在默认启动状态下根本看不见**。
///
/// 没有这些命令，验证就只能靠临时改代码，而临时改的代码不会留在仓库里，
/// 下一次复审的人也没有同样的入口。
///
/// ## 边界
///
/// 整份文件包在 `#if DEBUG` 里：正式构建里这些符号不存在，也不会有菜单项。
/// 它们**不改变默认启动状态**，只是把内容变成"点一下就能看到"。
@MainActor
enum DevelopmentCommands {

    /// 一次插入多少个元素。8 个既够看出网格排布，又不会让第一次运行就卡顿。
    static let batchSize = 8

    /// 已经真实入库的演示素材。每次启动为空：下一次启动再导入一份——
    /// 重复导入不合并（§7 第 4 条），演示素材也走同一口径。
    private static var demoAssetRecords: [AssetRecord] = []

    /// 往当前画布插入一批演示素材。
    ///
    /// 重复调用会继续追加（每次用新的元素 ID），所以"往画布上堆到很多元素"
    /// 也是点几下的事——B2 测 300/1000 元素会用到。
    ///
    /// C1 起演示内容走**真实导入**：像素管线是真实现（`FileImageProvider`，
    /// §3.2），合成素材没有文件、解码不出来。第一次点击把合成像素写成临时
    /// PNG、经 `ImportCoordinator` 入库；之后的点击只往画布摆元素，引用同一批
    /// 素材——与 B1 的行为一致。演示按钮因此顺带成了"点一下就踩一遍导入
    /// 通道"的日常验证。
    static func insertDemoBatch(into model: WorkspaceModel) async {
        guard !model.syntheticAssets.isEmpty else { return }
        if demoAssetRecords.isEmpty {
            demoAssetRecords = await importDemoFiles(into: model)
        }
        let records = demoAssetRecords
        guard !records.isEmpty else { return }

        var scene = model.scene
        let alreadyPlaced = scene.elements.count

        // 网格：四列，单元格 460 × 300 世界单位。
        //
        // **图按原比例放进单元格，不拉伸**：拉伸会掩盖"外框算错"这类问题——
        // 一张被拉变形的图看起来"填满了"，而正确的比例反而会露出空隙。
        // 单元格留白是有意为之。
        let columns = 4
        let cell = CGSize(width: 460, height: 300)
        let gap: CGFloat = 44

        // 摆在哪：**空白画布上以世界原点为中心**，否则接在已有内容的下方。
        //
        // 不居中的话这批内容会全部落在初始视野的右下角外面——第一次插入
        // 什么都看不见，得先"定位到全部内容"才看得到，而那一刻很容易被当成
        // "图片没显示出来"。摆在原点就不是问题：相机初始中心就是世界原点。
        let rows = (batchSize + columns - 1) / columns
        let gridSize = CGSize(
            width: CGFloat(columns) * cell.width + CGFloat(columns - 1) * gap,
            height: CGFloat(rows) * cell.height + CGFloat(rows - 1) * gap
        )
        let existing = scene.contentBounds
        let gridOrigin = existing.isNull
            ? CGPoint(x: -gridSize.width / 2, y: -gridSize.height / 2)
            : CGPoint(x: existing.minX, y: existing.maxY + gap)

        for offset in 0..<batchSize {
            let slot = alreadyPlaced + offset
            let record = records[slot % records.count]
            let aspect = record.pixelSize.width / max(1, record.pixelSize.height)

            var size = cell
            if aspect > cell.width / cell.height {
                size.height = (cell.width / aspect).rounded()
            } else {
                size.width = (cell.height * aspect).rounded()
            }

            let column = slot % columns
            let row = slot / columns
            let origin = CGPoint(
                x: gridOrigin.x + CGFloat(column) * (cell.width + gap) + (cell.width - size.width) / 2,
                y: gridOrigin.y + CGFloat(row) * (cell.height + gap) + (cell.height - size.height) / 2
            )

            scene.insert(CanvasElement(
                id: CanvasElementID(),
                kind: .image(asset: record.id),
                frame: CGRect(origin: origin, size: size),
                order: 0
            ))
        }

        model.applyScene(fromCanvas: scene)
    }

    /// 把合成素材写成临时 PNG（每个文件只写一次，之后复用）并真实入库。
    /// 只入库不摆画布——摆放是 `insertDemoBatch` 自己的网格。
    private static func importDemoFiles(into model: WorkspaceModel) async -> [AssetRecord] {
        let provider = SyntheticImageProvider(
            assets: model.syntheticAssets,
            cache: ImageCache()
        )
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pin-demo-assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var urls: [URL] = []
        for asset in model.syntheticAssets {
            let url = directory.appendingPathComponent("\(asset.id.raw.uuidString).png")
            if !FileManager.default.fileExists(atPath: url.path) {
                guard case .image(let image) = await provider.image(
                    for: asset.id,
                    targetPixelSize: asset.pixelSize
                ), let data = NSBitmapImageRep(cgImage: image)
                    .representation(using: .png, properties: [:])
                else { continue }
                try? data.write(to: url)
            }
            urls.append(url)
        }
        let outcomes = await model.importFiles(urls, placingOnCanvas: false)
        return model.syntheticAssets.compactMap { asset in
            let url = directory.appendingPathComponent("\(asset.id.raw.uuidString).png")
            guard case .imported(let record) = outcomes[url] else { return nil }
            return record
        }
    }

    /// 新建一块画布并切过去。
    ///
    /// 这条命令存在的唯一理由是**证明缓存的作用域**：如果解码缓存是按画布分的，
    /// 切回来会重新解码一遍，而那正是"切画布卡一下"的来源。`--selftest` 里有
    /// 对应断言，但断言只能证明代码路径，证明不了"来回切真的不卡"。
    /// 在新画布上也放一批素材，方便两块画布来回对比。
    static func seedNewBoard(in model: WorkspaceModel) async {
        guard await model.flushLibrary() == nil else { return }
        model.boards.addBoard()
        guard await model.flushLibrary() == nil else { return }
        await insertDemoBatch(into: model)
    }
}
#endif
