import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import WebKit

/// 相机与坐标换算的自检。
///
/// 决策 2(a) 之所以要求空画布也带平移缩放，是因为**坐标系得是真的**——只有真的
/// 能缩放平移，路线图 §4 规则 2 冻结的相机接口才有东西可审。但「能拖动」和
/// 「换算正确」是两回事：锚点算错时画面照样动，只是内容会慢慢漂走，
/// 肉眼几乎看不出来。
///
/// 所以这里把换算关系写成断言。跑法：`swift run PinNative --selftest`。
/// 返回非零退出码表示有断言失败，可以直接接进脚本。
@MainActor
enum SelfTest {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest")
    }

    private static var failures = 0
    private static var checks = 0

    static func runAndExit() async -> Never {
        cameraRoundTrip()
        anchoredZoomStability()
        zoomClamping()
        translateMatchesViewPoints()
        zoomRangeCoverage()
        fitPutsContentInViewport()
        gridSpacingStaysInBand()
        hitTestOrdering()
        sceneDiffIsComplete()
        sceneReachesRendererOnAttach()
        sceneReachesRendererOnUpdate()
        sceneCommandChannel()
        overlayChannel()
        materialSourceRegistry()
        boardCollection()
        boardSwitchReachesRenderer()
        dataDirectoryIsolation()
        lodTierSelection()
        imageCacheAccounting()
        await imageProviderContract()
        await imageReachesRenderer()
        await boardSwitchKeepsDecodedImages()
        await everyPixelNeedChangeRecomputesTier()
        await assetSwapReplacesPixels()
        lodHysteresisIsAsymmetric()
        await viewportVirtualizationKeepsLayerCountBounded()
        imageCacheBudgetAndMemoryPressure()
        imageResidencyLedger()
        await offscreenPixelsAreDropped()
        await staleDecodeIsCancelled()
        await imageFailureRetriesAndManualReload()
        await persistenceLayer()
        libraryRecoveryQuarantine()
        await fileImageProvider()
        await importCoordinator()
        await storageRetryAndImportReceipt()
        await clipboardImport()
        svgStructurePreservesExternalSemantics()
        dropInChannel()
        canvasAcceptsWebImageDrags()
        canvasContextMenuOffersPaste()
        await screenshotMaterialProvider()
        await restoreKeepsMissingFileElements()
        await importFeedbackSummary()
        await debugEntries()
        performanceProbeIsOffByDefault()
        floatingLayerSitsAboveCanvas()
        browserPanelIsWired()
        collapsedPanelLeavesAButton()
        panelWidthPolicyKeepsCanvasVisible()
        toolbarCollapsesFromTheRight()
        addressBarAcceptsOnlyWebURLs()
        canvasDoesNotDrawOutsideItsBounds()
        feelConfigurationIsWired()
        selectionGeometryIsExact()
        pointerSelectionAndMarquee()
        elementDragAndResize()
        responderChainActionsAreWired()
        undoOfDirectManipulation()
        selectionUndoAndHistoryLimit()
        panModesAndCursor()
        canvasToolbarBasics()
        await motionAnimationsReachTheTarget()

        print("")
        if failures == 0 {
            print("✅ \(checks) 项断言全部通过")
            exit(0)
        }
        print("❌ \(checks) 项断言中有 \(failures) 项失败")
        exit(1)
    }

    // MARK: - 断言框架

    private static func expect(
        _ condition: Bool,
        _ label: String,
        detail: @autoclosure () -> String = ""
    ) {
        checks += 1
        if condition {
            print("  ✓ \(label)")
        } else {
            failures += 1
            let extra = detail()
            print("  ✗ \(label)\(extra.isEmpty ? "" : " — \(extra)")")
        }
    }

    private static func nearlyEqual(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 1e-6) -> Bool {
        abs(a - b) <= tolerance
    }

    private static func nearlyEqual(_ a: CGPoint, _ b: CGPoint, tolerance: CGFloat = 1e-6) -> Bool {
        nearlyEqual(a.x, b.x, tolerance: tolerance) && nearlyEqual(a.y, b.y, tolerance: tolerance)
    }

    /// 矩形比较用在"自检自己算的可见矩形 vs 渲染器算的"上：两边的算式不同
    /// （一边是 `insetBy` 再换算，一边是直接加减半宽），末位必然有差异。
    private static func nearlyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1e-6) -> Bool {
        nearlyEqual(a.origin, b.origin, tolerance: tolerance)
            && nearlyEqual(a.size.width, b.size.width, tolerance: tolerance)
            && nearlyEqual(a.size.height, b.size.height, tolerance: tolerance)
    }

    /// 一组覆盖实际的相机状态：不同缩放、不同中心、不同视口尺寸。
    private static let samples: [CanvasCamera] = [
        CanvasCamera(center: .zero, zoom: 1, viewportSize: CGSize(width: 1280, height: 800)),
        CanvasCamera(center: CGPoint(x: 320, y: -180), zoom: 2.5,
                     viewportSize: CGSize(width: 1024, height: 700)),
        CanvasCamera(center: CGPoint(x: -4200, y: 9100), zoom: 0.05,
                     viewportSize: CGSize(width: 1440, height: 900)),
        CanvasCamera(center: CGPoint(x: 0.5, y: 0.25), zoom: 48,
                     viewportSize: CGSize(width: 640, height: 480)),
    ]

    // MARK: - 断言

    /// 两个方向的换算必须互为逆运算。这是所有命中、吸附、辅助线的地基。
    private static func cameraRoundTrip() {
        print("坐标换算往返")
        let points = [
            CGPoint.zero,
            CGPoint(x: 137, y: -42),
            CGPoint(x: -9999.5, y: 12345.25),
        ]
        for camera in samples {
            for point in points {
                let back = camera.viewToWorld(camera.worldToView(point))
                expect(
                    nearlyEqual(back, point, tolerance: 1e-6),
                    "zoom=\(camera.zoom) 世界点往返",
                    detail: "期望 \(point)，得到 \(back)"
                )
            }
        }
    }

    /// 路线图 §3.2「缩放锚点稳定」：以某点为锚缩放后，该点下的世界坐标不得移动。
    /// 锚点算错的表现是连续捏合时内容缓慢漂移——单看一帧完全正常。
    private static func anchoredZoomStability() {
        print("缩放锚点稳定性（§3.2）")
        let anchors = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 640, y: 400),
            CGPoint(x: 1023, y: 699),
            CGPoint(x: 200, y: 650),
        ]
        for camera in samples {
            for anchor in anchors {
                let worldBefore = camera.viewToWorld(anchor)
                var zoomed = camera
                zoomed.zoom(by: 1.37, anchoredAtViewPoint: anchor)
                let worldAfter = zoomed.viewToWorld(anchor)
                expect(
                    nearlyEqual(worldBefore, worldAfter, tolerance: 1e-6),
                    "zoom=\(camera.zoom) 锚点 \(Int(anchor.x)),\(Int(anchor.y)) 下世界坐标不动",
                    detail: "缩放前 \(worldBefore)，缩放后 \(worldAfter)"
                )
                // 锚点在视图坐标里也不能动：这是同一件事的另一面，顺手一起验。
                let anchorViewAfter = zoomed.worldToView(worldBefore)
                expect(
                    nearlyEqual(anchorViewAfter, anchor, tolerance: 1e-6),
                    "zoom=\(camera.zoom) 锚点自身的视图位置不动",
                    detail: "期望 \(anchor)，得到 \(anchorViewAfter)"
                )
            }
        }
    }

    /// 连续缩放不得越过上下限。触控板一次捏合可以给出很大的增量。
    private static func zoomClamping() {
        print("缩放上下限")
        var camera = samples[0]
        for _ in 0..<200 {
            camera.zoom(by: 1.5, anchoredAtViewPoint: CGPoint(x: 100, y: 100))
        }
        expect(camera.zoom == CanvasCamera.maxZoom, "连续放大停在 maxZoom",
               detail: "得到 \(camera.zoom)")

        for _ in 0..<400 {
            camera.zoom(by: 0.5, anchoredAtViewPoint: CGPoint(x: 100, y: 100))
        }
        expect(camera.zoom == CanvasCamera.minZoom, "连续缩小停在 minZoom",
               detail: "得到 \(camera.zoom)")

        // 视口始终有效：即便缩到极值，换算也不该产生 NaN 或无穷。
        let point = camera.viewToWorld(CGPoint(x: 10, y: 10))
        expect(point.x.isFinite && point.y.isFinite, "极值缩放下换算结果有限")
    }

    /// 拖拽平移的手感取决于这条：视图上移动多少点，内容就跟着移动多少点。
    private static func translateMatchesViewPoints() {
        print("平移与视图点一致")
        let delta = CGSize(width: 137, height: -89)
        for camera in samples {
            let probe = CGPoint(x: 12, y: 34)
            let before = camera.worldToView(probe)
            var moved = camera
            moved.translate(byViewDelta: delta)
            let after = moved.worldToView(probe)
            expect(
                nearlyEqual(after.x - before.x, delta.width, tolerance: 1e-6) &&
                nearlyEqual(after.y - before.y, delta.height, tolerance: 1e-6),
                "zoom=\(camera.zoom) 位移恰好等于视图位移",
                detail: "期望 \(delta)，得到 \(CGSize(width: after.x - before.x, height: after.y - before.y))"
            )
        }
    }

    /// 缩放到上限时，可见世界范围应当缩小到 1/zoom——这是视口虚拟化的前提。
    private static func zoomRangeCoverage() {
        print("可见世界范围")
        for camera in samples {
            let visible = camera.visibleWorldRect()
            let expectedWidth = camera.viewportSize.width / camera.zoom
            expect(
                nearlyEqual(visible.width, expectedWidth, tolerance: 1e-6),
                "zoom=\(camera.zoom) 可见世界宽度 = 视口宽 / zoom",
                detail: "期望 \(expectedWidth)，得到 \(visible.width)"
            )
            // 视口中心必须对应相机中心，否则「定位内容」会偏。
            let centerWorld = camera.viewToWorld(
                CGPoint(x: camera.viewportSize.width / 2, y: camera.viewportSize.height / 2)
            )
            expect(
                nearlyEqual(centerWorld, camera.center, tolerance: 1e-6),
                "zoom=\(camera.zoom) 视口中心对应相机中心"
            )
        }
    }

    /// 「定位内容」后，内容矩形必须完整落在视口内。
    private static func fitPutsContentInViewport() {
        print("定位内容")
        let camera = samples[1]
        let content = CGRect(x: -2000, y: -1500, width: 4000, height: 3000)
        var fitted = camera
        fitted.fit(worldRect: content, padding: 48)

        let inView = fitted.worldToView(content)
        let viewport = CGRect(origin: .zero, size: fitted.viewportSize)
        expect(
            viewport.insetBy(dx: -0.5, dy: -0.5).contains(inView),
            "内容矩形落在视口内",
            detail: "内容视图框 \(inView)，视口 \(viewport)"
        )
        expect(
            nearlyEqual(inView.midX, viewport.midX, tolerance: 0.5) ||
            nearlyEqual(inView.midY, viewport.midY, tolerance: 0.5),
            "内容在至少一个方向上居中"
        )

        // 空场景不应把相机送进 NaN——批次 A 全是空场景，这条是主路径。
        var empty = camera
        empty.fit(worldRect: .zero)
        expect(
            empty.zoom.isFinite && empty.center.x.isFinite && empty.center.y.isFinite,
            "空内容时相机保持有限值",
            detail: "zoom=\(empty.zoom) center=\(empty.center)"
        )
    }

    /// 网格换挡：任何缩放级别下，屏幕上的网格间距都要落在可读区间内。
    /// 太小是一屏几百条线（绘制成本与视觉噪声），太大是画布上看不到参照。
    private static func gridSpacingStaysInBand() {
        print("网格间距换挡")
        var zoom: CGFloat = CanvasCamera.minZoom
        var worstLow: CGFloat = .greatestFiniteMagnitude
        var worstHigh: CGFloat = 0
        var worstLineCount: CGFloat = 0
        var offSequence: CGFloat?
        // 用一个宽视口估最坏情况下的线数。
        let viewportWidth: CGFloat = 1600

        while zoom <= CanvasCamera.maxZoom {
            let step = CanvasHostNSView.gridStep(forZoom: zoom)
            let spacingInPoints = step * zoom
            worstLow = min(worstLow, spacingInPoints)
            worstHigh = max(worstHigh, spacingInPoints)
            worstLineCount = max(worstLineCount, viewportWidth / spacingInPoints)

            // 换挡结果必须真的落在 1/2/5 × 10ⁿ 上，否则说明尾数逻辑写错了。
            let magnitude = pow(10, (log10(step)).rounded(.down))
            let mantissa = step / magnitude
            let isOnSequence = [1.0, 2.0, 5.0, 10.0].contains {
                nearlyEqual(mantissa, $0, tolerance: 1e-9)
            }
            if !isOnSequence, offSequence == nil { offSequence = mantissa }

            zoom *= 1.02
        }

        expect(offSequence == nil, "换挡结果落在 1/2/5×10ⁿ 序列上",
               detail: offSequence.map { "出现尾数 \($0)" } ?? "")
        // 取「最接近」时，屏幕间距的极值由换挡阈值（相邻两项的几何中点）决定。
        // 每一档的比值 = 选中值 / 该档边界，四档分别是：
        //   下限方向  1/√2=0.707  2/√10=0.632  5/√50=0.707  10/10=1
        //   上限方向  1/1=1        2/√2=1.414   5/√10=1.581  10/√50=1.414
        // 所以区间是 64 × [0.632, 1.581] ≈ [40.5, 101.2]。
        // 这个区间比 1/2/5 序列本身的 2.5 倍窄，正是「最接近」相对「向上取整」
        // （区间 64–160）的收益。
        expect(worstLow >= 40.0, "网格间距不窄于 40pt", detail: "最窄 \(worstLow)pt")
        expect(worstHigh <= 102.0, "网格间距不宽于 102pt", detail: "最宽 \(worstHigh)pt")
        // 一屏线数是绘制成本与视觉噪声的直接指标。
        expect(worstLineCount <= 40, "1600pt 宽视口内网格线不超过 40 条",
               detail: "最密 \(worstLineCount) 条")
    }

    /// 命中测试必须返回最上层元素，而不是任意一个。
    private static func hitTestOrdering() {
        print("命中顺序")
        var scene = CanvasScene()
        let lower = CanvasElementID()
        let upper = CanvasElementID()
        let asset = AssetID()
        scene.insert(CanvasElement(
            id: lower,
            kind: .image(asset: asset),
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            order: 0
        ))
        scene.insert(CanvasElement(
            id: upper,
            kind: .image(asset: asset),
            frame: CGRect(x: 50, y: 50, width: 100, height: 100),
            order: 0
        ))

        let overlap = CGPoint(x: 75, y: 75)
        expect(
            CanvasHitTest.topmostElement(at: overlap, in: scene) == upper,
            "重叠处命中较上层元素",
            detail: "得到 \(String(describing: CanvasHitTest.topmostElement(at: overlap, in: scene)))"
        )
        expect(
            CanvasHitTest.topmostElement(at: CGPoint(x: 10, y: 10), in: scene) == lower,
            "仅下层覆盖处命中下层"
        )
        expect(
            CanvasHitTest.topmostElement(at: CGPoint(x: 500, y: 500), in: scene) == nil,
            "空白处返回 nil"
        )

        let both = CanvasHitTest.elements(
            intersecting: CGRect(x: 0, y: 0, width: 200, height: 200),
            in: scene
        )
        expect(both.count == 2, "框选相交返回 2 个", detail: "得到 \(both.count)")

        // 置顶之后，重叠处应当改判。
        scene.bringToFront([lower])
        expect(
            CanvasHitTest.topmostElement(at: overlap, in: scene) == lower,
            "置顶后被置顶者优先命中"
        )
    }

    // MARK: - 「场景 → 渲染器 → 图层」闭环
    //
    // 这一组是审核 P1-01 的返修要求：第一版只把 `order` 和相机送给渲染器，
    // **从不送 inserted / updated / removed**，协调器初始化时也不做全量同步。
    // 后果是批次 B 往画布放第一个元素时它不会出现——而那时离缺陷引入已经过去
    // 一整个批次了。
    //
    // 所以断言必须读**真实的 CALayer 树**（`sublayerIDsInDrawOrder`），
    // 读渲染器自己的字典等于自证。

    /// 差异计算本身。纯函数，不建任何图层。
    private static func sceneDiffIsComplete() {
        print("场景差异计算（P1-01）")
        let asset = AssetID()
        let a = CanvasElementID()
        let b = CanvasElementID()

        let empty = CanvasScene()
        var one = empty
        one.insert(CanvasElement(id: a, kind: .image(asset: asset),
                                 frame: CGRect(x: 0, y: 0, width: 10, height: 10), order: 0))

        // 初始：空场景 → 非空场景，全部算插入。
        let first = one.change(from: empty)
        expect(first.inserted.map(\.id) == [a], "空 → 非空：全部算插入",
               detail: "得到 \(first.inserted.map(\.id))")
        expect(first.removed.isEmpty, "空 → 非空：没有移除")
        expect(first.order == [a], "空 → 非空：带出绘制顺序")

        // 无变化：必须是空差异，否则每次 SwiftUI 刷新都会重发一遍全量。
        expect(one.change(from: one).isEmpty, "同一场景：差异为空")

        var two = one
        two.insert(CanvasElement(id: b, kind: .image(asset: asset),
                                 frame: CGRect(x: 20, y: 0, width: 10, height: 10), order: 0))
        let second = two.change(from: one)
        expect(second.inserted.map(\.id) == [b], "新增一个：只报这一个插入")
        expect(second.updated.isEmpty && second.removed.isEmpty, "新增一个：不误报更新或移除")

        // 改外框 → updated。
        var moved = two
        moved.setFrame(CGRect(x: 99, y: 0, width: 10, height: 10), for: a)
        let third = moved.change(from: two)
        expect(third.updated.map(\.id) == [a] && third.inserted.isEmpty,
               "改外框：只报这一个更新")
        expect(third.order == nil, "改外框：不报顺序变化")

        // 删除 → removed，且带出新顺序。
        var trimmed = moved
        trimmed.remove([b])
        let fourth = trimmed.change(from: moved)
        expect(fourth.removed == [b] && fourth.inserted.isEmpty,
               "删除：只报这一个移除")
        expect(fourth.order == [a], "删除：带出新的绘制顺序")

        // 重排 → 顺序变化必须被报出来，否则图层顺序会停在旧状态。
        var reordered = two
        reordered.bringToFront([a])
        let fifth = reordered.change(from: two)
        expect(fifth.order == [b, a], "重排：报出新的绘制顺序",
               detail: "得到 \(String(describing: fifth.order))")

        // 换画布：不做逐元素比对，旧的全删、新的全插。
        let otherBoard = CanvasScene(boardID: UUID(), elements: [
            CanvasElement(id: a, kind: .image(asset: asset),
                          frame: CGRect(x: 5, y: 5, width: 10, height: 10), order: 0)
        ])
        let sixth = otherBoard.change(from: two)
        expect(sixth.removed.sorted(by: { $0.raw.uuidString < $1.raw.uuidString })
                == [a, b].sorted(by: { $0.raw.uuidString < $1.raw.uuidString }),
               "换画布：旧元素全部移除")
        expect(sixth.inserted.map(\.id) == [a], "换画布：新元素全部插入")
    }

    /// 挂载时就要把已有元素画出来。非空初始场景（恢复的画布）走这条路。
    private static func sceneReachesRendererOnAttach() {
        print("初始非空场景（P1-01）")
        let fixture = makeElementFixture(count: 3)
        let (coordinator, _) = makeCoordinator(scene: fixture.scene)

        expect(
            coordinator.renderedElementOrder == fixture.ids,
            "挂载后图层树里就是全部元素，顺序一致",
            detail: "期望 \(shortIDs(fixture.ids))，得到 \(shortIDs(coordinator.renderedElementOrder))"
        )
        expect(
            coordinator.renderedFrame(of: fixture.ids[0]) == fixture.scene.element(fixture.ids[0])?.frame,
            "图层外框等于场景里的世界外框",
            detail: "得到 \(String(describing: coordinator.renderedFrame(of: fixture.ids[0])))"
        )
    }

    /// 插入 / 更新 / 删除 / 重排四件事都要真的落到图层树上。
    private static func sceneReachesRendererOnUpdate() {
        print("增量同步到图层（P1-01）")
        let fixture = makeElementFixture(count: 2)
        let (coordinator, _) = makeCoordinator(scene: fixture.scene)
        let (first, second) = (fixture.ids[0], fixture.ids[1])

        // 插入
        let third = CanvasElementID()
        var withThird = fixture.scene
        withThird.insert(CanvasElement(
            id: third, kind: .image(asset: fixture.asset),
            frame: CGRect(x: 200, y: 200, width: 40, height: 40), order: 0
        ))
        coordinator.applySceneFromOutside(withThird)
        expect(coordinator.renderedElementOrder == [first, second, third],
               "插入：新元素出现在图层树末尾",
               detail: "得到 \(coordinator.renderedElementOrder.count) 个")

        // 更新
        let newFrame = CGRect(x: -50, y: -60, width: 33, height: 44)
        var moved = withThird
        moved.setFrame(newFrame, for: first)
        coordinator.applySceneFromOutside(moved)
        expect(coordinator.renderedFrame(of: first) == newFrame,
               "更新：图层外框跟着改",
               detail: "得到 \(String(describing: coordinator.renderedFrame(of: first)))")
        expect(coordinator.renderedElementOrder == [first, second, third],
               "更新：不改变顺序，也不重复建层")

        // 删除
        var trimmed = moved
        trimmed.remove([second])
        coordinator.applySceneFromOutside(trimmed)
        expect(coordinator.renderedElementOrder == [first, third],
               "删除：图层被移除",
               detail: "得到 \(coordinator.renderedElementOrder.count) 个")
        expect(coordinator.renderedFrame(of: second) == nil, "删除：被删元素的图层不残留")

        // 重排
        var reordered = trimmed
        reordered.bringToFront([first])
        coordinator.applySceneFromOutside(reordered)
        expect(coordinator.renderedElementOrder == [third, first],
               "重排：图层顺序改变",
               detail: "得到 \(shortIDs(coordinator.renderedElementOrder))")
    }

    /// 命令通道：输入层改场景的唯一入口，改完三边都要看到。
    private static func sceneCommandChannel() {
        print("场景命令通道（P1-02）")
        var published: [CanvasScene] = []
        let fixture = makeElementFixture(count: 1)
        let (coordinator, _) = makeCoordinator(scene: fixture.scene) { published.append($0) }

        let added = CanvasElementID()
        let element = CanvasElement(
            id: added, kind: .image(asset: fixture.asset),
            frame: CGRect(x: 10, y: 10, width: 20, height: 20), order: 0
        )

        coordinator.perform(.insert(element))
        expect(coordinator.renderedElementOrder.last == added, "insert 落到图层树")
        expect(coordinator.scene.element(added) != nil, "insert 落到场景")
        expect(published.last?.element(added) != nil, "insert 回写给 SwiftUI")

        // 查询通道要能看见刚插入的元素——这是选择逻辑的前提。
        expect(coordinator.hitTest(worldPoint: CGPoint(x: 15, y: 15)) == added,
               "命中通道查得到新元素")
        expect(
            coordinator.elements(intersecting: CGRect(x: 0, y: 0, width: 500, height: 500))
                .contains(added),
            "框选通道查得到新元素"
        )

        coordinator.perform(.setFrame(CGRect(x: 300, y: 300, width: 20, height: 20), for: added))
        expect(coordinator.renderedFrame(of: added)?.origin == CGPoint(x: 300, y: 300),
               "setFrame 落到图层")

        coordinator.perform(.remove([added]))
        expect(coordinator.renderedFrame(of: added) == nil, "remove 落到图层")

        // 空命令不应该产生回写，否则 SwiftUI 会被无意义地刷新。
        let countBefore = published.count
        coordinator.perform(.remove([added]))
        expect(published.count == countBefore, "重复 remove 不产生多余回写")

        // 选择通道
        coordinator.selection = [fixture.ids[0]]
        expect(coordinator.selection == [fixture.ids[0]], "选择状态可读写")
    }

    /// 覆盖层通道。批次 A 只验证"送得到"，选择框的画法属于批次 C。
    private static func overlayChannel() {
        print("覆盖层通道（P1-02）")
        let fixture = makeElementFixture(count: 1)
        let (coordinator, _) = makeCoordinator(scene: fixture.scene)

        expect(coordinator.renderedOverlay.isEmpty, "初始覆盖层为空")

        let frame = CGRect(x: 1, y: 2, width: 3, height: 4)
        coordinator.overlay = CanvasOverlay(selectionFrames: [frame])
        expect(coordinator.renderedOverlay.selectionFrames == [frame],
               "覆盖层送得到渲染器",
               detail: "得到 \(coordinator.renderedOverlay.selectionFrames)")

        coordinator.overlay = .empty
        expect(coordinator.renderedOverlay.isEmpty, "覆盖层可清空")
    }

    // MARK: - 闭环测试的脚手架

    /// 断言消息里只放 id 的前 4 位：完整 UUID 会把终端输出撑成一片乱码，
    /// 而 4 位足够区分测试里那两三个元素。
    private static func shortIDs(_ ids: [CanvasElementID]) -> String {
        ids.map { String($0.raw.uuidString.prefix(4)) }.joined(separator: ",")
    }

    private struct ElementFixture {
        let scene: CanvasScene
        let ids: [CanvasElementID]
        let asset: AssetID
    }

    /// 造一个含 `count` 个元素的非空场景。
    private static func makeElementFixture(count: Int) -> ElementFixture {
        let asset = AssetID()
        var scene = CanvasScene()
        var ids: [CanvasElementID] = []
        for index in 0..<count {
            let id = CanvasElementID()
            ids.append(id)
            scene.insert(CanvasElement(
                id: id,
                kind: .image(asset: asset),
                frame: CGRect(x: CGFloat(index) * 100, y: 0, width: 80, height: 60),
                order: 0
            ))
        }
        return ElementFixture(scene: scene, ids: ids, asset: asset)
    }

    /// 建一个真正挂到 `NSView` 上的协调器。走的是产品代码那条路，
    /// 不是另写一份等价逻辑——否则测的是测试自己的实现。
    private static func makeCoordinator(
        scene: CanvasScene,
        selection: Set<CanvasElementID> = [],
        configuration: MotionConfiguration = .default,
        images: (any ImageProvider)? = nil,
        retryPolicy: ImageRetryPolicy = .default,
        onSceneChange: @escaping (CanvasScene) -> Void = { _ in },
        onSelectionChange: @escaping (Set<CanvasElementID>) -> Void = { _ in }
    ) -> (CanvasHostView.Coordinator, CanvasHostNSView) {
        let coordinator = CanvasHostView.Coordinator(
            camera: .initial,
            scene: scene,
            selection: selection,
            configuration: configuration,
            // 合成素材：路线图 §6 要求测试只用合成素材，不碰旧图库。
            images: images ?? SyntheticImageProvider(assets: SyntheticImageProvider.makeAssets(count: 2)),
            // 断言的节奏压到毫秒级：默认是 0.5/1/2 秒，跑一遍要 3.5 秒，
            // 而"退避"这件事本身另有断言（见 `imageFailureRetriesAndManualReload`）。
            retryPolicy: retryPolicy,
            commands: CanvasCommandRelay(),
            onSceneChange: onSceneChange,
            onSelectionChange: onSelectionChange,
            onCameraChange: { _ in }
        )
        let view = CanvasHostNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        // **两件都要做，顺序也要一样**——产品里 `makeNSView` 做的就是这两步
        // （`view.context = coordinator` 然后 `coordinator.attach(to: view)`），
        // 它们是两个方向上的引用，谁也代替不了谁：
        //
        // - `view.context`：视图 → 协调器。视图转发输入、`undo(_:)`、`paste(_:)`
        //   全靠它。**少了它，视图就是个空壳**——`tryToPerform` 照样说"接住了"
        //   （方法在），但方法体里 `context?` 一路静默失败，什么都不发生。
        // - `attach(to:)`：协调器 → 视图。渲染器挂图层、撤销拿窗口的
        //   `UndoManager`、命令接线全靠它。
        //
        // 这里漏掉第一件很久没人发现：此前的断言都直接调
        // `coordinator.handlePointerDown(...)`，**绕开了视图**，于是怎么测都是绿的。
        // 是"走真响应链"那条断言（`responderChainActionsAreWired`）把它照出来的。
        view.context = coordinator
        coordinator.attach(to: view)
        return (coordinator, view)
    }

    // MARK: - 素材来源目录

    /// 新增素材来源应当是"在目录里加一条数据"，不是"改四个 switch"。
    ///
    /// 断言分三层：目录完整（漏字段的来源在界面上是空图标、空文案，不报错）、
    /// 图标名真的存在（SF Symbol 写错一个字就是一片空白，同样不报错）、
    /// 以及**面板读到的是空状态而不是加载中**。
    private static func materialSourceRegistry() {
        print("素材来源目录")

        let model = WorkspaceModel(environment: .resolve())
        let catalog = model.materialSources
        expect(!catalog.isEmpty, "目录非空")

        let ids = catalog.map(\.id)
        expect(Set(ids).count == ids.count, "来源标识不重复",
               detail: ids.map(\.raw).joined(separator: ","))
        expect(model.activeSourceID == ids[0], "默认选中第一个来源")
        expect(model.activeSource.id == ids[0], "当前来源解析到第一个")

        for source in catalog {
            let name = source.id.raw
            expect(!source.title.isEmpty, "\(name) 有标题")
            expect(!source.emptyTitle.isEmpty, "\(name) 有空状态标题")
            expect(!source.emptyMessage.isEmpty, "\(name) 有空状态说明")
            // SF Symbol 名写错不会报错，只会画不出东西。
            expect(
                NSImage(systemSymbolName: source.systemImage, accessibilityDescription: nil) != nil,
                "\(name) 的图标 \(source.systemImage) 存在"
            )
        }

        // 查得到自己；未知标识返回 nil 而不是回退到第一个——
        // 回退会让"来源被删掉"表现为"悄悄变成了截图源"。
        for source in catalog {
            expect(model.source(source.id)?.id == source.id, "按标识查回 \(source.id.raw)")
        }
        expect(model.source(MaterialSourceID("nobody")) == nil, "未知标识不返回来源")
        // 但 `activeSource` 必须有解：它是面板的入参，不能是可选。
        model.activeSourceID = MaterialSourceID("nobody")
        expect(model.activeSource.id == ids[0], "当前来源指向未知标识时回落到第一个")

        // 空状态文案是批次 A 交付的一部分，快照与验收都按这几句看。
        // 它们现在住在 `MaterialSource` 上而不是面板的 switch 里，这条断言
        // 保证搬家没有搬丢。
        expect(catalog.map(\.emptyTitle) == ["还没有截图", "还没有采集", "还没有字体"],
               "空状态标题与交付一致",
               detail: catalog.map(\.emptyTitle).joined(separator: "/"))

        materialContentStates(catalog)
        materialCatalogIsPerEnvironment()
    }

    /// 目录必须由 `AppEnvironment` 建出来，而不是全局常量。
    ///
    /// 理由是批次 C：真实提供者要拿数据目录，而目录按 profile 不同
    /// （`Pin/dev-cc` / `Pin/dev-codex` / `Pin`）。如果目录是 `static let`，
    /// 提供者就只能自己再解析一次环境——那就是第二处真源。
    ///
    /// 断言分两层：提供者**确实拿到了**那份环境（不是"参数在那儿但没接线"），
    /// 以及两次构建**各自独立**（不是退回全局共享一份）。
    private static func materialCatalogIsPerEnvironment() {
        let cc = AppEnvironment.resolve(environment: [:], bundleIdentifier: "com.pin.native.dev-cc")
        let codex = AppEnvironment.resolve(environment: [:], bundleIdentifier: "com.pin.native.dev-codex")
        expect(cc.dataDirectory != codex.dataDirectory, "两个 profile 的目录确实不同")

        let ccSources = MaterialSourceCatalog.make(environment: cc)
        let codexSources = MaterialSourceCatalog.make(environment: codex)

        // 各自独立：共用一份提供者的话，两个 profile 会共享内容状态，
        // 一边刷新会改掉另一边面板上显示的东西。
        let ccProviders = ccSources.map { ObjectIdentifier($0.provider) }
        let codexProviders = codexSources.map { ObjectIdentifier($0.provider) }
        expect(Set(ccProviders).isDisjoint(with: Set(codexProviders)),
               "两次构建的提供者互不共用")
        expect(ccSources.map(\.id) == codexSources.map(\.id),
               "来源标识与 profile 无关（数据目录才是按 profile 分的）")

        // 每个提供者手里就是传进去的那份环境。这一条是**换画布那类 bug 的同款**：
        // 提供者各自解析环境的话，界面读 dev-cc、面板读 dev-codex 不会有任何
        // 编译错误，只会在运行时给出另一份数据。
        for source in codexSources {
            expect(source.provider.environment.dataDirectory == codex.dataDirectory,
                   "\(source.id.raw) 的提供者拿到的是 codex 的目录",
                   detail: source.provider.environment.dataDirectory.path)
        }

        // 模型确实把自己那份环境交下去了。
        let model = WorkspaceModel(environment: codex)
        expect(model.materialSources.count == codexSources.count, "模型持有的来源数与目录一致")
        expect(model.environment.profile == .codex, "模型用的是传进去的那份环境")
        for source in model.materialSources {
            expect(source.provider.environment.dataDirectory == codex.dataDirectory,
                   "模型建的 \(source.id.raw) 提供者拿到的是模型的目录",
                   detail: source.provider.environment.dataDirectory.path)
        }
    }

    /// 内容状态机。面板按这四个状态渲染，批次 C 的真实现只管往里写。
    private static func materialContentStates(_ catalog: [MaterialSource]) {
        let item = MaterialItem(
            id: MaterialItemID(), title: "样例", thumbnail: nil, kind: .image
        )
        expect(MaterialSourceContent.idle.items.isEmpty, "idle 没有条目")
        expect(MaterialSourceContent.loading.items.isEmpty, "loading 没有条目")
        expect(MaterialSourceContent.loaded([]).items.isEmpty, "loaded 空列表没有条目")
        expect(MaterialSourceContent.loaded([item]).items.count == 1, "loaded 有条目")
        expect(MaterialSourceContent.failed("读取失败").items.isEmpty, "failed 没有条目")

        // 启动状态按提供者分两种：
        // - 占位提供者（花瓣/字体）**启动即 `.loaded([])`**。它们没有真的内容，
        //   若写成 `.idle` 而 `refresh()` 又什么都不做，面板会永远停在转圈——
        //   那看起来像卡死，不像空。
        // - 截图源是真提供者（§3.4），**启动 `.idle`**：内容要等库打开后的
        //   第一次 `refresh()`。启动即 `.loaded([])` 的话，会在 refresh 之前
        //   短暂显示"没有素材"，那同样是不实的状态。
        for source in catalog {
            if source.id == MaterialSourceCatalog.screenshots {
                expect(source.provider.content == .idle,
                       "截图提供者启动即 idle，等第一次刷新")
            } else {
                expect(source.provider.content == .loaded([]),
                       "\(source.id.raw) 的占位提供者启动即空列表")
            }
        }

        // 提供者每个来源各一份。共用一份的话，切来源会互相覆盖内容状态，
        // 而表现是"切回截图源看见的是花瓣的内容"。
        let providers = catalog.map { ObjectIdentifier($0.provider) }
        expect(Set(providers).count == providers.count, "每个来源有各自的提供者")
    }

    // MARK: - 画布集合

    /// 多画布的结构性保证。
    ///
    /// 本轮没有对应界面（路线图 §6：完整多画布管理另分阶段），但底层必须已经是
    /// 对的——否则加界面时要在"界面没写好"和"底层不对"之间两头怀疑。
    private static func boardCollection() {
        print("画布集合")

        let store = BoardStore(board: Board(name: "画布 1"))
        expect(store.boards.count == 1, "初始只有一块画布")
        expect(store.activeBoard.name == "画布 1", "初始画布是当前画布")
        // 场景自己带着画布标识——渲染器换画布时靠它判断"这是另一块画布"。
        expect(store.activeScene.boardID == store.activeBoard.id, "场景带着当前画布的标识")

        // 在一块画布上放元素。
        let fixture = makeElementFixture(count: 2)
        let first = store.activeBoard.id
        var scene = store.activeScene
        scene.insert(contentsOf: fixture.scene.elements)
        store.applyScene(scene)
        expect(store.activeScene.elements.count == 2, "元素写回当前画布")

        let second = store.addBoard()
        expect(store.boards.count == 2, "新建后有两块画布")
        expect(store.activeBoardID == second.id, "新建后切到新画布")
        expect(second.id != first, "新画布是新标识")
        expect(store.activeScene.elements.isEmpty, "新画布是空的")
        expect(store.activeScene.boardID == second.id, "新画布的场景带自己的标识")
        expect(store.scene(for: first)?.elements.count == 2, "旧画布的元素还在")

        // 相机按画布分开。共享一个相机会让另一块画布的内容"跳"到别处。
        store.activeCamera.zoom = 3
        store.select(first)
        expect(nearlyEqual(store.activeCamera.zoom, 1), "另一块画布的相机没被带着改",
               detail: "\(store.activeCamera.zoom)")
        store.select(second.id)
        expect(nearlyEqual(store.activeCamera.zoom, 3), "切回来相机还在原处",
               detail: "\(store.activeCamera.zoom)")

        // 选择按画布分开：选择里存的是元素 ID，旧画布的 ID 在新画布上不存在。
        store.applySelection([fixture.ids[0], fixture.ids[1]], for: first)
        expect(store.selection(for: first).count == 2, "选择按画布存")
        expect(store.activeSelection.isEmpty, "当前画布的选择不受另一块影响")

        // 视口尺寸是窗口的属性，每块画布都要知道——只写当前画布的话，
        // 切过去的画布会拿着过期尺寸算「定位内容」。
        store.updateViewport(size: CGSize(width: 1234, height: 567))
        expect(store.camera(for: first)?.viewportSize == CGSize(width: 1234, height: 567),
               "视口尺寸写给所有画布")
        expect(store.camera(for: second.id)?.viewportSize == CGSize(width: 1234, height: 567),
               "视口尺寸写给当前画布")

        // 改名。空名字必须被拒绝：画布列表里出现一个空白项之后用户没法找回它。
        store.rename(first, to: "  竞品分析  ")
        expect(store.boards.first { $0.id == first }?.name == "竞品分析", "改名去掉首尾空白")
        store.rename(first, to: "   ")
        expect(store.boards.first { $0.id == first }?.name == "竞品分析", "空名字被拒绝")

        // 默认名字不能撞上已有的。撞了的话画布列表里会出现两个同名项，
        // 而用户没有任何办法区分它们。
        let third = store.addBoard()
        expect(third.name == "画布 3", "默认名字按序号", detail: third.name)
        store.rename(third.id, to: "画布 4")
        let fourth = store.addBoard()
        expect(fourth.name == "画布 5", "默认名字绕开已被占用的序号", detail: fourth.name)
        let names = store.boards.map(\.name)
        expect(Set(names).count == names.count, "画布名字互不重复",
               detail: names.joined(separator: ","))

        // 新建时的名字规则必须和改名**是同一条**。独立复审报的正是这里不一致：
        // 改名挡空白名，新建却收下了——于是一块名字为空白的画布进了列表，
        // 而用户没有任何办法在列表里认出或点中它。
        let blank = store.addBoard(named: "   ")
        expect(!blank.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               "空白名字不会被原样收下（和改名同一条规则）",
               detail: "「\(blank.name)」")
        let padded = store.addBoard(named: "  灵感板  ")
        expect(padded.name == "灵感板", "新建时去掉首尾空白", detail: "「\(padded.name)」")
        let namesAfter = store.boards.map(\.name)
        expect(Set(namesAfter).count == namesAfter.count,
               "回落成默认名之后仍然不撞名",
               detail: namesAfter.joined(separator: ","))

        boardRemoval()
    }

    /// 删除的画布语义。单独一段，因为"删掉当前画布之后剩下什么"最容易留下
    /// 一个悬空的 `activeBoardID`——而那会一路传到渲染器，表现是画布空白但没有报错。
    private static func boardRemoval() {
        let store = BoardStore()
        let first = store.activeBoardID
        store.addBoard()
        store.addBoard()
        expect(store.boards.count == 3, "三块画布起步")

        let second = store.boards.filter { $0.id != first && $0.id != store.activeBoardID }
        guard let middle = second.first?.id else {
            expect(false, "有第二块画布可供删除")
            return
        }

        // 删非当前画布：当前画布不变。
        let active = store.activeBoardID
        expect(store.remove(middle), "删除非当前画布")
        expect(store.activeBoardID == active, "删非当前画布后当前画布不变")
        expect(store.scene(for: middle) == nil, "被删画布的场景一并清掉")

        // 删当前画布：落到剩下的一块，不留悬空标识。
        let doomed = store.activeBoardID
        expect(store.remove(doomed), "删除当前画布")
        expect(store.activeBoardID != doomed, "当前画布不再是已删的那块")
        expect(store.boards.contains { $0.id == store.activeBoardID }, "当前画布确实存在")
        expect(store.camera(for: doomed) == nil, "被删画布的相机一并清掉")

        // 最后一块删不掉：`boards` 永不为空是这里所有访问器的前提。
        expect(!store.remove(store.activeBoardID), "拒绝删除最后一块")
        expect(store.boards.count == 1, "最后一块仍在")
        expect(store.activeScene.boardID == store.activeBoard.id, "剩下这块仍是当前画布")
    }

    /// 换画布必须真的换掉画布上的内容。
    ///
    /// 走的是产品代码那条路：另一块画布的场景 → 差异计算 → 渲染器图层。
    /// 这条路在 P1-01 修好之前是断的（差异根本没送到渲染器），
    /// 也就是说"以后再支持多画布"会撞上一个已经存在的死通道。
    ///
    /// **它不覆盖 `change(from:)` 里换画布那个分支的缺失**：两块画布的元素 ID
    /// 不相交时，逐元素比对得出的结果和全量重建一样，这条断言照样全绿
    /// （注入缺陷实测）。钉住那个分支的是 `sceneDiffIsComplete()`。
    /// 这里验的是**管线**通不通，以及选择的下行通道。
    private static func boardSwitchReachesRenderer() {
        print("换画布 → 渲染器 → 选择 / 覆盖层")

        let store = BoardStore()
        let first = store.activeBoardID

        let fixture = makeElementFixture(count: 2)
        var sceneA = store.activeScene
        sceneA.insert(contentsOf: fixture.scene.elements)
        store.applyScene(sceneA)

        var selectionReports = 0
        let (coordinator, _) = makeCoordinator(
            scene: store.activeScene,
            onSelectionChange: { _ in selectionReports += 1 }
        )
        expect(coordinator.renderedElementOrder.count == 2, "第一块画布的元素已上屏",
               detail: shortIDs(coordinator.renderedElementOrder))

        // 切到第二块画布：内容整体换掉，而不是叠加。
        store.addBoard()
        coordinator.applySceneFromOutside(store.activeScene)
        expect(coordinator.renderedElementOrder.isEmpty, "换画布后旧元素全部移除",
               detail: shortIDs(coordinator.renderedElementOrder))

        let other = makeElementFixture(count: 3)
        var sceneB = store.activeScene
        sceneB.insert(contentsOf: other.scene.elements)
        store.applyScene(sceneB)
        coordinator.applySceneFromOutside(store.activeScene)
        expect(coordinator.renderedElementOrder.count == 3, "新画布的元素上屏",
               detail: shortIDs(coordinator.renderedElementOrder))
        expect(Set(coordinator.renderedElementOrder).isDisjoint(with: Set(fixture.ids)),
               "旧画布的元素没有留下")

        // 切回去，旧画布的元素应当原样回来。
        store.select(first)
        coordinator.applySceneFromOutside(store.activeScene)
        expect(Set(coordinator.renderedElementOrder) == Set(fixture.ids), "切回来旧元素原样回来",
               detail: shortIDs(coordinator.renderedElementOrder))

        // 覆盖层必须跟着画布走。
        //
        // 覆盖层用**世界坐标**描述当前这块画布上的东西：选择框是元素外框，辅助线是
        // 对齐位置。换一块画布之后同一组坐标指的是完全不同的地方——留着就是
        // "选中的是这块画布，画出来的是上一块画布的框"。
        coordinator.overlay = CanvasOverlay(selectionFrames: [
            CGRect(x: 0, y: 0, width: 10, height: 10)
        ])
        expect(!coordinator.renderedOverlay.isEmpty, "覆盖层已提交给渲染器")

        // 同一块画布上的场景变化不该清掉它：拖动元素时覆盖层要每帧更新，
        // 一并清掉的话选择框会闪烁。
        var nudged = store.activeScene
        nudged.setFrame(CGRect(x: 7, y: 7, width: 10, height: 10), for: fixture.ids[0])
        store.applyScene(nudged)
        coordinator.applySceneFromOutside(store.activeScene)
        expect(!coordinator.renderedOverlay.isEmpty, "同一块画布的场景更新不清覆盖层")

        store.addBoard()
        coordinator.applySceneFromOutside(store.activeScene)
        expect(coordinator.renderedOverlay.isEmpty, "换画布丢掉覆盖层")

        // 选择的下行通道。上行（输入层改的）要回报；下行（SwiftUI 推来的）不能回报，
        // 因为那是在 `updateNSView` 里发生的，回报等于在视图更新期间改 SwiftUI 状态。
        coordinator.selection = [fixture.ids[0]]
        expect(selectionReports == 1, "输入层改的选择回报给 SwiftUI")
        coordinator.applyExternalSelection([])
        expect(coordinator.selection.isEmpty, "外部推下来的选择生效")
        expect(selectionReports == 1, "外部推下来的选择不再回报")
        coordinator.applyExternalSelection([fixture.ids[1]])
        expect(coordinator.selection == [fixture.ids[1]], "外部推下来的选择可替换")
        expect(selectionReports == 1, "再次下行仍不回报")
    }

    /// 路线图 §6「原生版从全新空库开始」与 `GITHUB_MAINTENANCE_WORKFLOW.md` §7
    /// 「CC 和 Codex 使用不同的运行数据目录」。
    ///
    /// 这两条都是「不该发生的事」，光靠读代码很难确信——真正危险的不是写错路径，
    /// 是某天为了图方便把数据目录指到旧工作区里，而没有人注意到。
    private static func dataDirectoryIsolation() {
        print("数据目录隔离（§6）")

        let cc = AppEnvironment.dataDirectory(for: .cc)
        let codex = AppEnvironment.dataDirectory(for: .codex)
        let production = AppEnvironment.dataDirectory(for: .production)

        expect(cc != codex, "两个 profile 的数据目录不同",
               detail: "\(cc.path) vs \(codex.path)")
        expect(
            cc.lastPathComponent == "dev-cc" && codex.lastPathComponent == "dev-codex",
            "目录名带 profile 后缀"
        )
        // 正式版的数据目录不能和任何一个开发 profile 重合，否则真实数据会
        // 被开发调试覆盖（审核 P2-02）。
        expect(
            production != cc && production != codex && !production.path.hasPrefix(cc.path),
            "正式版数据目录与开发 profile 分开",
            detail: "\(production.path)"
        )

        // 绝不能落在任何一个旧工作区里。这三条路径是本轮明确要求不碰的。
        let forbidden = [
            "/Users/huwenhao12/Documents/截图分析管理工具",
            "/Users/huwenhao12/Documents/截图分析管理工具-cc",
            "/Users/huwenhao12/Documents/截图分析管理工具-native",
        ]
        for path in [cc.path, codex.path, production.path] {
            for prefix in forbidden {
                expect(
                    !path.hasPrefix(prefix + "/"),
                    "数据目录不在旧工作区内",
                    detail: "\(path) 落在 \(prefix)"
                )
            }
        }

        // MARK: profile 解析规则（审核 P2-02 的返修要求）

        // 显式环境变量优先。裸可执行文件（swift run）没有 bundle identifier，
        // 只有这条路能落到 cc。
        let noBundle = AppEnvironment.resolveProfile(environment: [:], bundleIdentifier: nil)
        expect(noBundle == .cc, "无环境变量、无 bundle id（swift run）默认 cc",
               detail: "得到 \(noBundle)")

        let viaEnvironment = AppEnvironment.resolveProfile(
            environment: [AppEnvironment.profileEnvironmentKey: "codex"],
            bundleIdentifier: nil
        )
        expect(viaEnvironment == .codex, "环境变量可切换 profile")

        expect(
            AppEnvironment.resolveProfile(
                environment: [AppEnvironment.profileEnvironmentKey: "CODEX"],
                bundleIdentifier: nil
            ) == .codex,
            "环境变量大小写不敏感"
        )

        // **关键一条**：拼错的 profile 绝不能静默回退。
        // 第一版是 `?? .cc`，Codex 打错一个字母就会去写 Claude 的数据目录。
        let typo = AppEnvironment.resolveProfile(
            environment: [AppEnvironment.profileEnvironmentKey: "codxe"],
            bundleIdentifier: nil
        )
        expect(typo == .unsupported, "拼错的 profile 不回退，标记为 unsupported",
               detail: "得到 \(typo)")
        expect(typo != .cc, "拼错的 profile 不会落进 cc 的数据目录")

        // 双击 .app 拿不到环境变量，所以 bundle identifier 必须自己带够信息。
        let cases: [(String, AppEnvironment.Profile)] = [
            ("com.pin.native.dev-cc", .cc),
            ("com.pin.native.dev-codex", .codex),
            ("com.pin.native", .production),
            ("com.example.somethingelse", .production),
        ]
        for (identifier, expected) in cases {
            let resolved = AppEnvironment.resolveProfile(
                environment: [:], bundleIdentifier: identifier
            )
            expect(resolved == expected, "bundle id \(identifier) → \(expected)",
                   detail: "得到 \(resolved)")
        }

        // 打包出来的开发包绝不能落到别人的目录：这正是审核里那条
        // "Codex 双击普通 Pin.app 就进了 dev-cc" 的回归断言。
        expect(
            AppEnvironment.dataDirectory(for:
                AppEnvironment.resolveProfile(
                    environment: [:], bundleIdentifier: "com.pin.native.dev-codex"
                )
            ).lastPathComponent == "dev-codex",
            "双击 Codex 包进 dev-codex，不进 dev-cc"
        )
    }
    // MARK: - 图片管线（B1）

    /// 档位算错的表现是"缩放时缓存永不命中"——画面照样能看，只是每次缩放都
    /// 重新解码。这种问题只有数字能发现，肉眼看不出。
    private static func lodTierSelection() {
        print("解码档位")
        let uhd = CGSize(width: 3840, height: 2160)

        expect(LODTier.fitting(CGSize(width: 3840, height: 2160), original: uhd) == .full,
               "需求等于原图 → 原分辨率档")
        expect(LODTier.fitting(CGSize(width: 1920, height: 1080), original: uhd).level == 1,
               "需求减半 → 1/2 档")
        expect(LODTier.fitting(CGSize(width: 480, height: 270), original: uhd).level == 3,
               "需求 1/8 → 1/8 档")

        // 两个轴都要覆盖。只按宽度选档的话，细长图会在那个档位上被拉糊。
        let wide = CGSize(width: 4000, height: 1000)
        expect(LODTier.fitting(CGSize(width: 900, height: 400), original: wide).level == 1,
               "高度不够时按高度选档，不只看宽度",
               detail: "只看宽度会得到 2")

        expect(LODTier.fitting(CGSize(width: 8000, height: 8000), original: uhd) == .full,
               "需求超过原图 → 仍是原分辨率档（不做无意义的超采样）")
        expect(LODTier.fitting(CGSize(width: 1, height: 1), original: uhd).level == LODTier.maximumLevel,
               "需求极小 → 停在最粗一档，不无限降")

        expect(LODTier(level: 2).pixelSize(forOriginal: uhd) == CGSize(width: 960, height: 540),
               "1/4 档的解码尺寸")
        expect(LODTier.full.pixelSize(forOriginal: CGSize(width: 3, height: 1))
                == CGSize(width: 3, height: 1),
               "原图比档位还小时不塌成 0（0 宽的位图建不出来）")

        // 把"为什么必须做 LOD"变成数字。路线图 §2.4 要测 20 张不同的 4K 图。
        let uhdBytes = Int(uhd.width * uhd.height) * 4
        expect(uhdBytes == 33_177_600, "一张 4K 解码后 31.6 MB", detail: "\(uhdBytes) 字节")
        expect(uhdBytes * 20 == 663_552_000,
               "20 张 4K 全按原分辨率留着 = 632 MB——这就是缓存预算的依据")
    }

    /// 缓存账面。预算和淘汰算错不会报错，只会让内存慢慢涨上去，
    /// 或者在某个不起眼的时刻开始每帧重新解码。
    private static func imageCacheAccounting() {
        print("解码缓存账面")
        guard let padded = makeBlankImage(CGSize(width: 100, height: 100)),
              let small = makeBlankImage(CGSize(width: 64, height: 64)),
              let large = makeBlankImage(CGSize(width: 256, height: 256))
        else {
            expect(false, "造测试位图")
            return
        }

        let asset = AssetID()
        let tierA = LODTier(level: 0)
        let tierB = LODTier(level: 1)

        // 账面必须按**行宽 × 高**算，因为 CoreGraphics 的行宽带对齐填充
        // （100 像素宽的行是 416 字节，不是 400）。用 64 这类本来就对齐的宽度
        // 验不出差别——那种尺寸下两种算法给出同一个数，断言无论实现对错都通过。
        let ledger = ImageCache(byteBudget: 10 * 1024 * 1024)
        ledger.store(padded, for: asset, tier: tierA)
        expect(ledger.totalBytes == padded.bytesPerRow * padded.height,
               "账面 = 行宽 × 高（行宽不是 width × 4）",
               detail: "期望 \(padded.bytesPerRow * padded.height)，得到 \(ledger.totalBytes)")
        expect(padded.bytesPerRow != 100 * 4,
               "守一下上面那条：这张图的行宽确实带填充",
               detail: "行宽 \(padded.bytesPerRow)——等于 400 的话上面那条就验不出东西了")
        expect(ledger.entry(for: asset, tier: tierA)?.pixelSize == CGSize(width: 100, height: 100),
               "记录里带着实际像素尺寸")

        // 单张比预算还大：不许把它自己淘汰掉——那会让大图永远进不了缓存，
        // 每次重绘都重新解码，比多占一点内存糟得多。
        let cache = ImageCache(byteBudget: 100 * 1024)
        cache.store(small, for: asset, tier: tierA)
        cache.store(large, for: asset, tier: tierB)
        expect(cache.count == 1, "超预算时淘汰最久未用的那条")
        expect(cache.peek(for: asset, tier: tierB) != nil,
               "留下的是刚存的那张，大图不把自己挤出去")

        // LRU 顺序：新存两个、摸热一个、再存第三个，被淘汰的必须是没被摸过的那个。
        let lru = ImageCache(byteBudget: 40 * 1024)
        let a1 = AssetID(), a2 = AssetID(), a3 = AssetID()
        lru.store(small, for: a1, tier: tierA)
        lru.store(small, for: a2, tier: tierA)
        _ = lru.image(for: a1, tier: tierA)
        lru.store(small, for: a3, tier: tierA)
        expect(lru.peek(for: a2, tier: tierA) == nil, "淘汰的是最久未用的那条")
        expect(lru.peek(for: a1, tier: tierA) != nil, "刚访问过的不淘汰")
        expect(lru.peek(for: a3, tier: tierA) != nil, "新存的不淘汰")

        let before = lru.totalBytes
        lru.store(small, for: a1, tier: tierA)
        expect(lru.totalBytes == before, "同一键重复存入不虚增账面",
               detail: "存前 \(before)，存后 \(lru.totalBytes)")
    }

    /// 提供者的契约。四条各自钉一件事：元数据不解码、缺素材与解码失败分得开、
    /// 档位真的落在尺寸上、以及**解码不在主线程**。
    private static func imageProviderContract() async {
        print("素材取像素")
        let assets = SyntheticImageProvider.makeAssets(count: 3)
        let cache = ImageCache()
        let provider = SyntheticImageProvider(assets: assets, cache: cache)
        let first = assets[0]

        let metadata = await provider.metadata(for: first.id)
        expect(metadata?.pixelSize == first.pixelSize, "元数据给出原图尺寸")
        expect(provider.decodeCount == 0, "读元数据不触发解码",
               detail: "解码 \(provider.decodeCount) 次")

        let ghost = AssetID()
        let ghostMetadata = await provider.metadata(for: ghost)
        expect(ghostMetadata == nil, "未知素材没有元数据")

        // 「没有」和「坏了」必须分得开：给用户的说法完全不同，
        // 而链路上把它们并成一个 nil 之后就再也分不开了。
        let ghostResult = await provider.image(for: ghost, targetPixelSize: CGSize(width: 100, height: 100))
        if case .missing = ghostResult {
            expect(true, "未知素材取像素 → missing，不是 failed")
        } else {
            expect(false, "未知素材取像素 → missing，不是 failed", detail: "\(ghostResult)")
        }

        // 目标尺寸刻意取在**两档之间**（520 落在 1/2 档的 1920 和 1/4 档的 960
        // 之间，但真正的分界在 960 与 480 之间）：正好压在档位边界上的话，
        // "按档位解码"和"按精确尺寸解码"给出同一个数，断言就验不出差别了。
        let target = CGSize(width: 520, height: 293)
        let tier = LODTier.fitting(target, original: first.pixelSize)
        let firstResult = await provider.image(for: first.id, targetPixelSize: target)
        guard case .image(let image) = firstResult else {
            expect(false, "取到像素", detail: "\(firstResult)")
            return
        }
        let expected = tier.pixelSize(forOriginal: first.pixelSize)
        expect(CGSize(width: image.width, height: image.height) == expected,
               "解码尺寸落在算出来的档位上",
               detail: "期望 \(Int(expected.width))×\(Int(expected.height))，得到 \(image.width)×\(image.height)")
        expect(provider.decodeCount == 1, "解码了一次")
        expect(provider.lastDecodeWasOffMainThread == true,
               "解码不在主线程（§2.4「主线程 P95 < 8ms」的前提）",
               detail: "得到 \(String(describing: provider.lastDecodeWasOffMainThread))")

        _ = await provider.image(for: first.id, targetPixelSize: target)
        expect(provider.decodeCount == 1, "同一档位重取命中缓存，不重新解码")

        _ = await provider.image(for: first.id, targetPixelSize: CGSize(width: 120, height: 68))
        expect(provider.decodeCount == 2, "换一档要重新解码")
        expect(cache.count == 2, "两个档位各占一条缓存记录")

        // 缓存键是「素材 × 档位」，不是「元素」——同一素材在画布上出现三次
        // 只占一条，这是"一张素材多次进入画布"（§5 必测场景）不爆内存的前提。
        _ = await provider.image(for: first.id, targetPixelSize: target)
        expect(cache.count == 2, "同一素材重复请求不新增缓存记录",
               detail: "记录数 \(cache.count)")
    }

    /// 图片真的进了图层。读的是 `layer.contents`，不是渲染器自己的记账。
    private static func imageReachesRenderer() async {
        print("图片 → 渲染器 → 图层")
        let assets = SyntheticImageProvider.makeAssets(count: 2)
        let provider = SyntheticImageProvider(assets: assets)
        let asset = assets[0]
        let id = CanvasElementID()

        // 外框按原图比例给，和导入时的做法一致。
        let width: CGFloat = 400
        let height = (width * asset.pixelSize.height / asset.pixelSize.width).rounded()
        var scene = CanvasScene()
        scene.insert(CanvasElement(
            id: id,
            kind: .image(asset: asset.id),
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            order: 0
        ))

        let counting = CountingImageProvider(provider)
        let (coordinator, _) = makeCoordinator(scene: scene, images: counting)
        expect(coordinator.renderedImageSize(of: id) == nil,
               "刚挂载时还没有像素（解码是异步的）")

        let loaded = await waitUntil("图层拿到像素") {
            coordinator.renderedImageSize(of: id) != nil
        }
        guard loaded else {
            expect(false, "图层最终拿到像素",
                   detail: "取不到，失败原因 \(coordinator.renderedImageFailures)")
            return
        }

        let size = coordinator.renderedImageSize(of: id)!
        // 缩放为 1、backingScale 为 2 → 需要 800×? 像素，原图 4K 够用，
        // 所以档位应当选在"刚好覆盖 800 像素宽"那一档上。
        let expectedTier = coordinator.renderedTier(of: id)
        expect(expectedTier != nil, "渲染器记下了当前档位")
        expect(size == expectedTier?.pixelSize(forOriginal: asset.pixelSize),
               "图层里的像素尺寸就是该档位的尺寸",
               detail: "得到 \(Int(size.width))×\(Int(size.height))")
        expect(coordinator.renderedImageFailures[id] == nil,
               "没有解码失败", detail: "\(coordinator.renderedImageFailures)")
        // 真图到了，**底色必须整块撤掉**：底色画在 `contents` 后面，留着它，
        // 带透明通道的素材在画布上就自带一个底（产品负责人实测反馈的"透明 PNG
        // 显示成灰块"）。这一条与"没铺失败色"分开：失败色只是底色的一种。
        expect(!coordinator.hasBackingColor(id),
               "真图到位之后图层不留任何底色（透明区域要透出画布本身）")

        // 档位没变就不该再问提供者。每次相机变化都会走一遍档位评估，少了
        // 「档位没变就返回」那道闸，每个滚轮事件都会重新发一次请求——缓存挡得住
        // 解码，但挡不住请求本身在主线程上的开销，而 §2.4 卡的是主线程。
        let requestsBefore = counting.requestCount
        var nudged = coordinator.camera
        nudged.zoom = 1.02        // 同一个档位以内
        coordinator.applyExternalCamera(nudged)
        expect(coordinator.renderedTier(of: id) == expectedTier,
               "微调缩放没跨档", detail: "\(String(describing: coordinator.renderedTier(of: id)))")
        // 这里必须**先等一小会儿再数**。请求是异步发出去的，同步数一定数到
        // 请求之前的值——那样这条断言不管实现对错都通过（缺陷注入时它不变红，
        // 也就等于没有）。这是全文件唯一一处固定 sleep 是对的：要在等的是一件
        // **不该发生**的事，而"不该发生"没有可轮询的终点。
        try? await Task.sleep(nanoseconds: 60_000_000)
        expect(counting.requestCount == requestsBefore,
               "档位没变时不重复发请求",
               detail: "之前 \(requestsBefore) 次，之后 \(counting.requestCount) 次")

        // 缩小时应当换到更粗的一档——但**不许把内容清空**（§2.3 禁止空白闪烁）。
        //
        // 这里分两步断言，因为"不闪白"是**换档那一瞬间**的性质，轮询看不见：
        // 轮询只能看见结果，看不见中间有没有空过一帧。而换档是同步发生的
        // （`refreshImageTiers`），解码是异步的——`applyExternalCamera` 返回的
        // 那一刻图层里必然还是旧档的像素，这是唯一能确定性地抓到它的时刻。
        var coarserCamera = coordinator.camera
        coarserCamera.zoom = 0.1
        coordinator.applyExternalCamera(coarserCamera)

        // 问的是**要哪一档**（`requestedTier`），不是"图层里已经是哪一档"
        // （`renderedTier`）：换档是同步判定的，像素还在路上。两件事分开之后
        // 这条断言才真的在验它要验的东西。
        let coarser = coordinator.requestedTier(of: id)
        expect(coarser != expectedTier, "缩小时换档",
               detail: "仍是 \(String(describing: coarser))")
        expect(coordinator.renderedImageSize(of: id) == size,
               "换档瞬间图层里还是旧档的像素，不是空的（不清空 = 不闪白）",
               detail: "得到 \(String(describing: coordinator.renderedImageSize(of: id)))")

        let coarserSize = coarser?.pixelSize(forOriginal: asset.pixelSize)
        let swapped = await waitUntil("新档位的像素落到图层") {
            coordinator.renderedImageSize(of: id) == coarserSize
        }
        expect(swapped, "新档解码完成后替换上去",
               detail: "期望 \(String(describing: coarserSize))，得到 \(String(describing: coordinator.renderedImageSize(of: id)))")
        expect(provider.decodeCount >= 2, "换档确实解码了新的一档",
               detail: "解码 \(provider.decodeCount) 次")

        // 迟到的旧档结果不许覆盖新档。
        //
        // 这是"越缩放越糊"的成因：连续缩放时好几个解码同时在飞，先发的后到，
        // 后到的又是更粗的一档。它只在**时序**上错，代码读起来完全正常，
        // 所以只能造一个可控的慢档把它逼出来——把粗档拖慢，让它在细档之后到达。
        await assertLateResultIsDiscarded(asset: asset)
    }

    /// 让粗档的解码晚于细档返回，验证代次令牌真的把迟到结果丢掉了。
    private static func assertLateResultIsDiscarded(asset: SyntheticImageProvider.Asset) async {
        let provider = SyntheticImageProvider(assets: [asset])
        let id = CanvasElementID()
        let width: CGFloat = 400
        let height = (width * asset.pixelSize.height / asset.pixelSize.width).rounded()
        var scene = CanvasScene()
        scene.insert(CanvasElement(
            id: id,
            kind: .image(asset: asset.id),
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            order: 0
        ))

        // 挂载时（缩放 1）落在粗档，把它拖慢；放大后要的细档不拖。
        let coarse = LODTier.fitting(CGSize(width: width * 2, height: height * 2), original: asset.pixelSize)
        let slow = DelayedTierProvider(wrapping: provider, slowLevel: coarse.level, delay: 0.5)

        let (coordinator, _) = makeCoordinator(scene: scene, images: slow)
        // 挂载时还不知道原图尺寸（元数据也是异步的），所以档位不是立刻就有的。
        // 要等它落到粗档、慢请求**真的发出去了**，放大才有东西可抢。
        let started = await waitUntil("粗档请求已发出") { coordinator.requestedTier(of: id) == coarse }
        expect(started, "挂载时先按粗档请求",
               detail: "\(String(describing: coordinator.requestedTier(of: id)))")
        expect(coordinator.renderedImageSize(of: id) == nil,
               "粗档还没回来（就是它要迟到）")

        var zoomed = coordinator.camera
        zoomed.zoom = 4
        coordinator.applyExternalCamera(zoomed)

        let fine = coordinator.requestedTier(of: id)
        expect(fine == .full, "放大后要原分辨率档", detail: "\(String(describing: fine))")
        let fineSize = fine?.pixelSize(forOriginal: asset.pixelSize)
        _ = await waitUntil("细档先到") { coordinator.renderedImageSize(of: id) == fineSize }

        // 等到超过粗档的延迟：它一定已经回来了。回来了但**不该生效**。
        try? await Task.sleep(nanoseconds: 900_000_000)
        expect(coordinator.renderedImageSize(of: id) == fineSize,
               "迟到的粗档结果被丢弃，没有把画面换回糊的",
               detail: "期望 \(String(describing: fineSize))，得到 \(String(describing: coordinator.renderedImageSize(of: id)))")
    }

    /// 只改一个行为、其余**全部原样转发**的提供者。自检里的假提供者都从它派生。
    ///
    /// 为什么要有这个基类：`ImageProvider` 上有两个成员（`residency` 与
    /// `cachedImage`）与"被测的那一件事"毫无关系，每个假提供者各写一遍就是四份
    /// 要同步维护的样板。而漏掉其中一个的表现是**账本少记一笔**——内存看着正常、
    /// 实际一直涨，正是缺陷 ③ 的形态。转发一次，四处都对。
    @MainActor
    private class ForwardingImageProvider: ImageProvider {
        let wrapped: any ImageProvider

        init(_ wrapped: any ImageProvider) { self.wrapped = wrapped }

        var residency: ImageResidency { wrapped.residency }

        func metadata(for asset: AssetID) async -> ImageMetadata? {
            await wrapped.metadata(for: asset)
        }

        func cachedImage(for asset: AssetID, atMost tier: LODTier) -> CachedImage? {
            wrapped.cachedImage(for: asset, atMost: tier)
        }

        func releaseOffscreenPixels(of asset: AssetID) {
            wrapped.releaseOffscreenPixels(of: asset)
        }

        func image(for asset: AssetID, targetPixelSize: CGSize) async -> ImageRequestResult {
            await wrapped.image(for: asset, targetPixelSize: targetPixelSize)
        }
    }

    /// 只数请求次数，别的原样转发。
    ///
    /// "渲染器会不会每帧重复发请求"读代码看不出来——它取决于几个 guard 的组合，
    /// 而那正是最容易在某次改动里被顺手删掉的东西。
    @MainActor
    private final class CountingImageProvider: ForwardingImageProvider {
        private(set) var requestCount = 0

        override func image(for asset: AssetID, targetPixelSize: CGSize) async -> ImageRequestResult {
            requestCount += 1
            return await super.image(for: asset, targetPixelSize: targetPixelSize)
        }
    }

    /// 把某一档的解码拖慢。除了拖延，其余行为与内层完全一致——**缓存也共用**，
    /// 所以被拖慢的只有时间，不是内容。
    @MainActor
    private final class DelayedTierProvider: ForwardingImageProvider {
        private let slowLevel: Int
        private let delay: TimeInterval

        init(wrapping wrapped: SyntheticImageProvider, slowLevel: Int, delay: TimeInterval) {
            self.slowLevel = slowLevel
            self.delay = delay
            super.init(wrapped)
        }

        override func image(for asset: AssetID, targetPixelSize: CGSize) async -> ImageRequestResult {
            if let metadata = await wrapped.metadata(for: asset),
               LODTier.fitting(targetPixelSize, original: metadata.pixelSize).level == slowLevel {
                // 拖延放在委托**之前**：无论内层是解码还是命中缓存，迟到都会发生。
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            return await super.image(for: asset, targetPixelSize: targetPixelSize)
        }
    }

    /// 解码缓存是**全局共享**的，不按画布分。
    ///
    /// 这条是上一轮"多画布"预留接口的延伸：缓存要是被渲染器持有，切画布就清空，
    /// 切回来全部重解码——而那正是"切画布卡一下"的来源。断言只能证明代码路径，
    /// 真正的"来回切不卡"要人手动确认（`⌘⇧B`）。
    private static func boardSwitchKeepsDecodedImages() async {
        print("换画布不丢已解码图片")
        let assets = SyntheticImageProvider.makeAssets(count: 2)
        let provider = SyntheticImageProvider(assets: assets)
        let asset = assets[0]

        var first = CanvasScene(boardID: UUID())
        let firstID = CanvasElementID()
        first.insert(CanvasElement(id: firstID, kind: .image(asset: asset.id),
                                   frame: CGRect(x: 0, y: 0, width: 400, height: 225), order: 0))

        let (coordinator, _) = makeCoordinator(scene: first, images: provider)
        _ = await waitUntil("第一块画布出图") { coordinator.renderedImageSize(of: firstID) != nil }
        let afterFirst = provider.decodeCount
        expect(afterFirst >= 1, "第一块画布解码过", detail: "解码 \(afterFirst) 次")

        // 换到另一块画布：同一张素材再出现一次。
        var second = CanvasScene(boardID: UUID())
        let secondID = CanvasElementID()
        second.insert(CanvasElement(id: secondID, kind: .image(asset: asset.id),
                                    frame: CGRect(x: 0, y: 0, width: 400, height: 225), order: 0))
        coordinator.applySceneFromOutside(second)
        _ = await waitUntil("第二块画布出图") { coordinator.renderedImageSize(of: secondID) != nil }
        expect(provider.decodeCount == afterFirst,
               "另一块画布用同一档位时不再解码（缓存按素材共享，不按画布）",
               detail: "换画布前 \(afterFirst) 次，换后 \(provider.decodeCount) 次")

        // 切回来：还是不该解码。
        coordinator.applySceneFromOutside(first)
        _ = await waitUntil("切回第一块画布出图") { coordinator.renderedImageSize(of: firstID) != nil }
        expect(provider.decodeCount == afterFirst,
               "切回来也不解码", detail: "解码 \(provider.decodeCount) 次")
    }

    // MARK: - 像素需求变化的每一条路径

    /// 一个元素需要多少像素，只由**三样东西**决定：外框、相机缩放、屏幕倍率。
    /// 三样各有一条改动路径，每条都必须重算档位。
    ///
    /// 这条是独立复审报回来的缺陷：捏合与工具条动画**直接写 `renderer.camera`**，
    /// 而重算档位当时挂在"渲染增量"那条路上（`apply` / `updateLayerFrames`），
    /// 两条路不是同一条。表现是**放大后画面停在低清档**——矩阵确实更新了，
    /// 所以读代码看不出来，截图也看不出来（糊与不糊在同一张静态图上都要对比才认得出）。
    ///
    /// 屏幕倍率那一条是我自查同一类缺陷时发现的：`setBackingScaleFactor` 只把
    /// 图层的 `contentsScale` 改了，没有重算档位，于是从 1× 屏拖到 2× 屏之后，
    /// 图层按 2× 放大一份 1× 的像素。
    private static func everyPixelNeedChangeRecomputesTier() async {
        print("像素需求的每一条路径都要重算档位")
        let assets = SyntheticImageProvider.makeAssets(count: 1)
        let provider = SyntheticImageProvider(assets: assets)
        let asset = assets[0]
        let id = CanvasElementID()
        let width: CGFloat = 400
        let height = (width * asset.pixelSize.height / asset.pixelSize.width).rounded()
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        var scene = CanvasScene()
        scene.insert(CanvasElement(
            id: id,
            kind: .image(asset: asset.id),
            frame: frame,
            order: 0
        ))

        let counting = CountingImageProvider(provider)
        let (coordinator, _) = makeCoordinator(scene: scene, images: counting)
        // 自检里视图没有窗口，宿主挂载时取的是默认值 2（见 `attach(to:)`）。
        // 后面每一段的期望值都**独立算一遍**，不读渲染器自己记的档位——
        // 拿它的记账当期望值的话，"它没换档"和"它换对了档"会给出同一个数。
        let mountScale: CGFloat = 2

        let loaded = await waitUntil("挂载出图") { coordinator.renderedImageSize(of: id) != nil }
        guard loaded else {
            expect(false, "挂载后拿到像素",
                   detail: "失败 \(coordinator.renderedImageFailures)")
            return
        }

        // 六段，每段走一条路径，且**每段的落点都要求一个与上一段不同的档位**。
        // 这一点是刻意的：如果一段的落点恰好与上一段同档，那么缺陷还在时它照样绿
        // （画面里本来就是那一档的像素），等于没有牙。
        //
        // 期望值不读渲染器的记账（那是自证），而是"测试自己记的上一档 + 纯函数策略"
        // 算出来的。**带迟滞的选档与"从哪一档出发"有关**，所以测试必须自己维护
        // 那条轨迹——这也是为什么期望值不能只按相机参数算（见 `expectedPixelSize`）。
        let headroom = coordinator.motionConfiguration.lod.downgradeHeadroom
        var expectedTier = LODTier.fitting(
            CGSize(width: frame.width * mountScale, height: frame.height * mountScale),
            original: asset.pixelSize
        )
        expect(coordinator.renderedImageSize(of: id)
                == expectedTier.pixelSize(forOriginal: asset.pixelSize),
               "挂载时按当前需求解像素（还没有上一档，选档就是「刚好覆盖需求」）",
               detail: "应解 \(Int(expectedTier.pixelSize(forOriginal: asset.pixelSize).width)) 宽，实际 \(String(describing: coordinator.renderedImageSize(of: id)))")

        // 1) 屏幕倍率（2 → 3）。视口尺寸**特意保持不变**：需要多少像素与视口尺寸
        //    无关，变的只有 backingScaleFactor。1 倍缩放下的需求从 800 涨到 1200
        //    像素宽：1/4 档的 960 不够了，得换到 1/2 档。
        coordinator.updateViewport(size: coordinator.viewportSize, backingScaleFactor: 3)
        let rescaled = expectedPixelSize(
            frame: frame, zoom: 1, backingScale: 3,
            from: expectedTier, headroom: headroom, original: asset.pixelSize
        )
        expect(rescaled.tier != expectedTier,
               "这一段的落点确实要求另一档（否则这条断言验不出东西）",
               detail: "上一段是 \(expectedTier.level) 档，这一段是 \(rescaled.tier.level) 档")
        let previousTier = expectedTier
        expectedTier = rescaled.tier
        let scaleApplied = await waitUntil("3× 下该有的像素落到图层") {
            coordinator.renderedImageSize(of: id) == rescaled.size
        }
        expect(scaleApplied, "屏幕倍率变了要重算档位（换到高密度屏不能还按 1× 的像素解）",
               detail: "\(previousTier.level) 档 → \(rescaled.tier.level) 档，应解 \(Int(rescaled.size.width))×\(Int(rescaled.size.height))，实际 \(String(describing: coordinator.renderedImageSize(of: id)))")

        // 2) 工具条缩放走缓动——**每一帧**都是直接写相机，所以终态那一帧写完
        //    必须已经换档。等终态而不是掐中间帧：中间帧在哪一刻到是不可靠的。
        var animated = MotionConfiguration.default
        animated.programmaticCameraDuration = 0.12
        coordinator.setMotionConfiguration(animated)
        coordinator.handleZoomStep(4)
        let settled = await waitUntil("缓动到终态") { coordinator.camera.zoom == 4 }
        expect(settled, "缓动结束时相机到了 4 倍", detail: "zoom \(coordinator.camera.zoom)")

        let zoomedIn = expectedPixelSize(
            frame: frame, zoom: 4, backingScale: 3,
            from: expectedTier, headroom: headroom, original: asset.pixelSize
        )
        expect(zoomedIn.tier != expectedTier,
               "这一段的落点确实要求另一档（否则这条断言验不出东西）",
               detail: "上一段是 \(expectedTier.level) 档，这一段是 \(zoomedIn.tier.level) 档")
        expectedTier = zoomedIn.tier
        let animated4x = await waitUntil("4 倍下该有的像素落到图层") {
            coordinator.renderedImageSize(of: id) == zoomedIn.size
        }
        expect(animated4x, "工具条缓动放大后像素跟着换（每一帧都在直接写相机）",
               detail: "4 倍下应解 \(Int(zoomedIn.size.width))×\(Int(zoomedIn.size.height))，实际 \(String(describing: coordinator.renderedImageSize(of: id)))")

        // 3) 捏合缩小到 1 倍。负增量是真实存在的（两指收拢），
        //    倍率 1 + (-0.75)×1 = 0.25，从 4 倍落到 1 倍。
        //
        //    落点特意选在 1 倍而不是 2 倍：从 4 倍缩到 2 倍时迟滞**故意不换档**
        //    （那一档还没有 1.414 倍的余量），拿 2 倍当落点的话这条断言在缺陷
        //    还在时也会是绿的——画面里本来就是那一档的像素。这正是上一轮记下的
        //    那条教训：落点必须要求一个与上一段不同的档位。
        let center = CGPoint(x: 400, y: 300)
        let pinchCamera = coordinator.handleMagnify(CanvasMagnifyInput(
            viewPoint: center, worldPoint: center, magnification: -0.75,
            phase: .changed, modifiers: .none
        ))
        expect(pinchCamera.zoom == 1, "捏合把相机收到 1 倍", detail: "zoom \(pinchCamera.zoom)")

        let pinchedExpectation = expectedPixelSize(
            frame: frame, zoom: 1, backingScale: 3,
            from: expectedTier, headroom: headroom, original: asset.pixelSize
        )
        expect(pinchedExpectation.tier != expectedTier,
               "捏合的落点确实要求另一档（否则这条断言验不出东西）",
               detail: "上一段是 \(expectedTier.level) 档，这一段是 \(pinchedExpectation.tier.level) 档")
        expectedTier = pinchedExpectation.tier
        let pinched = await waitUntil("1 倍下该有的像素落到图层") {
            coordinator.renderedImageSize(of: id) == pinchedExpectation.size
        }
        expect(pinched, "捏合缩放后图层里的像素跟着换（不是只更新矩阵）",
               detail: "1 倍下应解 \(Int(pinchedExpectation.size.width))×\(Int(pinchedExpectation.size.height))，实际 \(String(describing: coordinator.renderedImageSize(of: id)))，渲染器记的档位 \(String(describing: coordinator.renderedTier(of: id)?.level))")

        // 4) 平移只改相机中心，档位一个都不该动。这一段的动机来自本轮修法本身：
        //    重算改挂到相机 setter 上之后，**拖拽平移的每一帧都会走一遍档位扫描**。
        //    扫描不该变成重发请求——重算是"算一遍要不要换"，换不换还得看档位变没变。
        //    少了这一条，我的修法就可能用"每帧重发"换来"档位正确"。
        let centerBeforePan = coordinator.camera.center
        let requestsBefore = counting.requestCount
        let panned = coordinator.handleScroll(CanvasScrollInput(
            viewPoint: center, worldPoint: center,
            delta: CGSize(width: 40, height: 25),
            isPrecise: true, phase: .changed, momentumPhase: .none, modifiers: .none
        ))
        expect(panned.center != centerBeforePan, "滚动确实平移了相机",
               detail: "中心 \(centerBeforePan) → \(panned.center)")
        // 先等再数：请求是异步发出去的（同 `imageReachesRenderer` 里那条）。
        try? await Task.sleep(nanoseconds: 60_000_000)
        expect(counting.requestCount == requestsBefore,
               "平移不重复发请求（相机变了，但档位一个都没变）",
               detail: "平移前 \(requestsBefore) 次，平移后 \(counting.requestCount) 次")
        let pannedExpectation = expectedPixelSize(
            frame: frame, zoom: 1, backingScale: 3,
            from: expectedTier, headroom: headroom, original: asset.pixelSize
        )
        expect(pannedExpectation.tier == expectedTier,
               "平移后的档位与平移前一致（这一段的期望本身就是不换档）",
               detail: "平移前 \(expectedTier.level) 档，平移后 \(pannedExpectation.tier.level) 档")
        expect(coordinator.renderedImageSize(of: id) == pannedExpectation.size,
               "平移不换像素", detail: "\(String(describing: coordinator.renderedImageSize(of: id)))")

        // 5) 迟滞**实测**（不只是纯函数那一组）：从 1 倍缩到 2/3 倍，需求掉到 800
        //    像素宽。按"刚好覆盖需求"的算法这里是 1/4 档，而迟滞要求下一档还得有
        //    1.414 倍的余量——800×1.414 = 1131 > 960，所以**不降档**，画面继续停在
        //    1/2 档上。
        //
        //    这一段的期望值与无迟滞的算法**故意不同**，所以它是"迟滞真的接上线了"
        //    的证据：把 `settled` 换回 `fitting`，这段立刻转红（纯函数那组只能证明
        //    函数对，证明不了调用点用的是它）。
        let thirdOut = coordinator.handleMagnify(CanvasMagnifyInput(
            viewPoint: center, worldPoint: center, magnification: -1.0 / 3.0,
            phase: .changed, modifiers: .none
        ))
        expect(nearlyEqual(thirdOut.zoom, 2.0 / 3.0), "缩到 2/3 倍", detail: "zoom \(thirdOut.zoom)")
        let held = expectedPixelSize(
            frame: frame, zoom: 2.0 / 3.0, backingScale: 3,
            from: expectedTier, headroom: headroom, original: asset.pixelSize
        )
        expect(held.tier == expectedTier,
               "迟滞在这一步选择不降档（否则这一段验的不是迟滞）",
               detail: "上一档 \(expectedTier.level)，这一步算出来还是 \(held.tier.level)")
        let withoutHysteresis = LODTier.fitting(
            CGSize(width: frame.width * (2.0 / 3.0) * 3,
                   height: frame.height * (2.0 / 3.0) * 3),
            original: asset.pixelSize
        )
        expect(withoutHysteresis != held.tier,
               "无迟滞的算法在这里会降到另一档（这就是迟滞挡掉的那次重解码）",
               detail: "无迟滞会到 \(withoutHysteresis.level) 档，实际停在 \(held.tier.level) 档")
        // 给它足够时间"错误地"换一档：这一段的判据是**没有变化**，
        // 不等一下的话，"还没来得及换"和"确实不换"分不开。
        try? await Task.sleep(nanoseconds: 80_000_000)
        expect(coordinator.renderedImageSize(of: id) == held.size,
               "缩到 2/3 倍时档位不动（迟滞生效：余量不够就不降）",
               detail: "应保持 \(Int(held.size.width))×\(Int(held.size.height))，实际 \(String(describing: coordinator.renderedImageSize(of: id)))")

        // 6) 继续缩到 1/3 倍：需求 400 像素宽。下一档（960）的余量够了
        //    （400×1.414 = 566 ≤ 960），所以**该降了**——降一级，停在 1/4 档。
        //    这一段是上一条的反面：只有它才能证明迟滞不是"永不降档"。
        //
        //    落点选 1/3 而不是别的值，是因为它同时满足两个条件：
        //
        //    - 需求（400）**稳稳落在某一档内部**（1/8 档是 480 宽，1/16 档是 240），
        //      离两边的边界都有两成以上的余量。落在边界上的话，浮点误差会让
        //      "刚好覆盖需求是哪一档"在相邻两档之间跳，那一段就等于没验（这是
        //      实测踩到的：0.4 倍的需求正好是 480 = 1/8 档的宽度，实际算出来比
        //      480 大一丁点，于是提供者那边判出的是 1/4 档，而迟滞判出的是 1/8 档
        //      ——两个不同的结论在那一刻**碰巧**给出了同一张图，缺陷因此藏住了）。
        //    - **无迟滞的算法在这里会走得更粗**（需求 400 < 480，落 1/8 档），
        //      而迟滞停在 1/4 档。于是这一段顺带把"渲染器把已经定下来的那一档
        //      传给了提供者"也钉住了：传原始需求的话，提供者会按无迟滞的算法
        //      再判一次，图层里出现的是更粗的那一档（实测：这条能让它转红）。
        let further = 0.5 - 1
        let outFurther = coordinator.handleMagnify(CanvasMagnifyInput(
            viewPoint: center, worldPoint: center, magnification: CGFloat(further),
            phase: .changed, modifiers: .none
        ))
        expect(nearlyEqual(outFurther.zoom, 1.0 / 3.0), "缩到 1/3 倍",
               detail: "zoom \(outFurther.zoom)")
        let steppedDown = expectedPixelSize(
            frame: frame, zoom: 1.0 / 3.0, backingScale: 3,
            from: expectedTier, headroom: headroom, original: asset.pixelSize
        )
        expect(steppedDown.tier != expectedTier,
               "这一段的落点确实要求另一档（否则这条断言验不出东西）",
               detail: "上一段是 \(expectedTier.level) 档，这一段是 \(steppedDown.tier.level) 档")
        let coarserThanExpected = LODTier.fitting(
            CGSize(width: frame.width * (1.0 / 3.0) * 3,
                   height: frame.height * (1.0 / 3.0) * 3),
            original: asset.pixelSize
        )
        expect(coarserThanExpected != steppedDown.tier,
               "无迟滞的算法在这里落得更粗（这一段同时钉住「请求传的是定下来的那一档」）",
               detail: "无迟滞会到 \(coarserThanExpected.level) 档，迟滞停在 \(steppedDown.tier.level) 档")
        expectedTier = steppedDown.tier
        let stepped = await waitUntil("1/3 倍下该有的像素落到图层") {
            coordinator.renderedImageSize(of: id) == steppedDown.size
        }
        expect(stepped, "继续缩小后档位真的往下走了一级（迟滞不是「永不降档」）",
               detail: "1/3 倍下应解 \(Int(steppedDown.size.width))×\(Int(steppedDown.size.height))，实际 \(String(describing: coordinator.renderedImageSize(of: id)))")
    }

    /// 元素在给定相机参数下**从上一档出发**应当显示多少像素。
    ///
    /// 与 `demandedPixelSize`（纯 `fitting`，回答"刚好覆盖需求是哪一档"）的区别就在
    /// `from:` 上：B2 的选档带迟滞，同样的需求从不同的档位出发会得到不同结果。
    /// 调用方传的是**测试自己记的上一档**，不是渲染器的记账——读渲染器的记账等于
    /// 自证；读纯函数则是把策略本身也一起断言（策略的数值在迟滞那一组里按手算的
    /// 数字钉住，不靠这里兜底）。
    private static func expectedPixelSize(
        frame: CGRect,
        zoom: CGFloat,
        backingScale: CGFloat,
        from current: LODTier,
        headroom: CGFloat,
        original: CGSize
    ) -> (tier: LODTier, size: CGSize) {
        let tier = LODTier.settled(
            CGSize(width: frame.width * zoom * backingScale,
                   height: frame.height * zoom * backingScale),
            original: original,
            from: current,
            headroom: headroom
        )
        return (tier, tier.pixelSize(forOriginal: original))
    }

    /// 某个元素在给定相机状态下**应该**解出多少像素。独立算一遍，
    /// 不读渲染器的记账——断言读被测方自己的账等于自证。
    private static func demandedPixelSize(
        frame: CGRect,
        zoom: CGFloat,
        backingScale: CGFloat,
        original: CGSize
    ) -> CGSize {
        LODTier.fitting(
            CGSize(width: frame.width * zoom * backingScale,
                   height: frame.height * zoom * backingScale),
            original: original
        ).pixelSize(forOriginal: original)
    }

    /// 同一个元素换了素材、**外框和档位都没变**时，图层必须换成新素材的像素。
    ///
    /// 这条也是独立复审报回来的：`requestImage` 当时只比档位（`displayedTier`），
    /// 不比素材。档位是"多少像素"，素材是"哪张图"——两个都在变的东西只比了一个，
    /// 于是换图之后画面**继续显示旧图**，而所有记账看起来都是对的。
    ///
    /// 两个合成素材特意选得"档位相同、像素不同"：3840×2160 与 3456×2234 在同一个
    /// 需求下都落在 1/4 档，但解出来是 960×540 与 864×558。断言读的是图层里
    /// **实际的像素尺寸**，所以它能分辨"换了"和"没换"。
    private static func assetSwapReplacesPixels() async {
        print("同一元素换素材要换像素")
        let assets = SyntheticImageProvider.makeAssets(count: 2)
        let provider = SyntheticImageProvider(assets: assets)
        let first = assets[0]
        let second = assets[1]
        let id = CanvasElementID()
        let frame = CGRect(x: 0, y: 0, width: 400, height: 225)

        var scene = CanvasScene()
        scene.insert(CanvasElement(id: id, kind: .image(asset: first.id), frame: frame, order: 0))

        let (coordinator, _) = makeCoordinator(scene: scene, images: provider)
        let loaded = await waitUntil("第一张素材出图") { coordinator.renderedImageSize(of: id) != nil }
        guard loaded, let firstSize = coordinator.renderedImageSize(of: id) else {
            expect(false, "第一张素材出图", detail: "失败 \(coordinator.renderedImageFailures)")
            return
        }

        // 换素材，**外框一动不动**。用同 ID、同 boardID 的新场景推下去，
        // 走的是产品里那条「场景 → 渲染器」的同步通路（`change(from:)` 会
        // 因为 `kind` 不同把它判成 updated）。
        var swapped = CanvasScene(boardID: scene.boardID)
        swapped.insert(CanvasElement(id: id, kind: .image(asset: second.id), frame: frame, order: 0))

        let beforeTier = LODTier.fitting(
            CGSize(width: frame.width * coordinator.camera.zoom * 2,
                   height: frame.height * coordinator.camera.zoom * 2),
            original: first.pixelSize
        )
        let afterTier = LODTier.fitting(
            CGSize(width: frame.width * coordinator.camera.zoom * 2,
                   height: frame.height * coordinator.camera.zoom * 2),
            original: second.pixelSize
        )
        expect(beforeTier == afterTier,
               "两张素材在这一档上确实同档（否则这条断言验的不是「只比档位」）",
               detail: "第一张 \(beforeTier.level) 档，第二张 \(afterTier.level) 档")

        coordinator.applySceneFromOutside(swapped)
        let expected = demandedPixelSize(
            frame: frame, zoom: coordinator.camera.zoom, backingScale: 2, original: second.pixelSize
        )
        let replaced = await waitUntil("换成第二张素材的像素") {
            coordinator.renderedImageSize(of: id) == expected
        }
        expect(replaced, "档位没变也要换像素（换素材不是换档位）",
               detail: "期望 \(Int(expected.width))×\(Int(expected.height))，得到 \(String(describing: coordinator.renderedImageSize(of: id)))，换之前是 \(Int(firstSize.width))×\(Int(firstSize.height))")
        expect(coordinator.renderedImageFailures[id] == nil,
               "换素材没有报失败", detail: "\(coordinator.renderedImageFailures)")
    }

    /// 等一个异步结果落地。
    ///
    /// 渲染器的图片请求是"发出去就不管"的（没有回调），所以测试只能等。
    /// 用**有上限的轮询**而不是固定 sleep：固定 sleep 要么短了偶发失败，
    /// 要么长了每次都白等。条件成立就立刻返回。
    private static func waitUntil(
        _ label: String,
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }

    /// 造一张空白位图，用来验缓存账面。
    private static func makeBlankImage(_ pixelSize: CGSize) -> CGImage? {
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage()
    }
    // MARK: - B2：迟滞、虚拟化、缓存预算、取消

    /// 换档迟滞：**升级立刻、降级要有余量**。
    ///
    /// 全在纯函数上跑。迟滞最容易出的错是"某个方向上永远换不了档"，而那种状态
    /// **只有真实的缩放序列才碰得到**——在画布上捏合几十次也未必撞上，撞上了
    /// 也只是觉得"有点糊"。把整条轨迹直接喂进纯函数，一次跑完。
    ///
    /// 这里按手算的数字钉住策略本身；「策略真的接在渲染器上」那件事在
    /// `everyPixelNeedChangeRecomputesTier` 的第 5、6 段验（把余量去掉，那两段
    /// 会转红）——纯函数这一组证明不了调用点用的是它。
    private static func lodHysteresisIsAsymmetric() {
        print("换档迟滞")
        let uhd = CGSize(width: 3840, height: 2160)
        let headroom = MotionConfiguration.default.lod.downgradeHeadroom
        func demand(_ width: CGFloat) -> CGSize { CGSize(width: width, height: width * 9 / 16) }
        func settled(_ width: CGFloat, from current: LODTier?, headroom: CGFloat) -> LODTier {
            LODTier.settled(demand(width), original: uhd, from: current, headroom: headroom)
        }
        let half = LODTier(level: 1)
        let quarter = LODTier(level: 2)

        expect(headroom > 1, "迟滞默认开着（余量 > 1）", detail: "headroom \(headroom)")

        // 升级那一侧没有可调参数：需求一涨过当前档就换，慢了就是糊。
        expect(settled(1500, from: quarter, headroom: headroom) == half,
               "需求涨过当前档 → 立刻换细",
               detail: "得到 \(settled(1500, from: quarter, headroom: headroom).level) 档")
        expect(settled(1500, from: quarter, headroom: headroom)
                == LODTier.fitting(demand(1500), original: uhd),
               "升级那一侧与「刚好覆盖需求」完全一致（这一侧没有旋钮）")

        // 降级那一侧：需求 900 时「刚好覆盖需求」是 1/4 档（960），但
        // 900 × 1.414 = 1273 > 960，余量不够，所以停在 1/2 档。
        expect(LODTier.fitting(demand(900), original: uhd) == quarter,
               "守一下：900 的「刚好覆盖需求」确实是 1/4 档")
        expect(settled(900, from: half, headroom: headroom) == half,
               "需求缩到下一档的边上，余量不够 → 不降",
               detail: "得到 \(settled(900, from: half, headroom: headroom).level) 档")
        expect(settled(600, from: half, headroom: headroom) == quarter,
               "余量够了才降（600×1.414 = 848 ≤ 960）",
               detail: "得到 \(settled(600, from: half, headroom: headroom).level) 档")

        // 边界上来回抖动：这一串全是「刚好跨过 1/4 档边界」的量级。无迟滞时它们
        // 会在两档之间来回跳，每一次跳都是一次解码——而两次解码的画面看起来
        // 一模一样，用户只会觉得"缩放到这儿会卡一下"。
        let jitter: [CGFloat] = [900, 960, 880, 1000, 940, 905]
        expect(jitter.allSatisfy { settled($0, from: half, headroom: headroom) == half },
               "在档位边界附近来回缩放不换档",
               detail: jitter.map { "\(Int($0))→\(settled($0, from: half, headroom: headroom).level)档" }
                   .joined(separator: " "))
        let flapping = jitter.filter { settled($0, from: half, headroom: 1) != half }
        expect(flapping.count >= 2,
               "守一下上面那条：把余量去掉，这一串确实会跳",
               detail: "无迟滞时 \(flapping.count) 次会换档：\(flapping.map { Int($0) })")

        // 一把缩到底：**逐级**判，不是只判终点。
        //
        // 只判终点的话，终点那一档必然没有余量（它本来就是"刚好覆盖需求"的那一档），
        // 于是一路都不许降——从原分辨率一把缩到底，画面仍然停在最细的档上白占内存。
        // 这是写这一版时改掉的第一版实现，所以留一条断言钉住它。
        let deep = settled(110, from: .full, headroom: headroom)
        expect(deep == LODTier(level: 4),
               "从最细一档一把缩到底：走到底前那一级停住，不卡在最细的档上",
               detail: "得到 \(deep.level) 档")
        expect(LODTier.fitting(demand(110), original: uhd) == LODTier(level: 5),
               "守一下：无迟滞时它会走到更粗的一档（所以上面那条验的是迟滞）")
        expect(deep.pixelSize(forOriginal: uhd).width >= 110,
               "停在那一档也仍然覆盖得住需求（不糊）",
               detail: "\(Int(deep.pixelSize(forOriginal: uhd).width)) 像素宽 ≥ 110")

        // 两条不变量，对所有起点都成立——它们就是迟滞的全部承诺：
        // 「画面不会糊」和「不会因为一次抖动去解一张更大的图」。
        var neverBlurry = true
        var neverFinerThanNeeded = true
        for width in stride(from: CGFloat(20), through: 4000, by: 37) {
            let demanded = LODTier.fitting(demand(width), original: uhd)
            for level in 0...LODTier.maximumLevel {
                let current = LODTier(level: level)
                let result = LODTier.settled(demand(width), original: uhd,
                                             from: current, headroom: headroom)
                if result.level > demanded.level { neverBlurry = false }
                if result.level < min(current.level, demanded.level) { neverFinerThanNeeded = false }
            }
        }
        expect(neverBlurry, "任何起点下都不会停在比需求更粗的档上（不糊）")
        expect(neverFinerThanNeeded,
               "任何起点下都不会比「当前档与需求档里更细的那个」还细（不为一次抖动解更大的图）")

        // 余量 = 1 必须退化成 B1 的行为（文档里那句等价关系的实证）。
        var equalsFitting = true
        for width in stride(from: CGFloat(20), through: 4000, by: 53) {
            for level in 0...LODTier.maximumLevel {
                let result = LODTier.settled(demand(width), original: uhd,
                                             from: LODTier(level: level), headroom: 1)
                if result != LODTier.fitting(demand(width), original: uhd) { equalsFitting = false }
            }
        }
        expect(equalsFitting, "余量 = 1 时退化成「刚好覆盖需求」（等于没有迟滞）")
        expect(settled(800, from: nil, headroom: headroom)
                == LODTier.fitting(demand(800), original: uhd),
               "还没有上一档时（元素刚进画布）就是「刚好覆盖需求」")
    }

    /// 视口虚拟化：只有**看得见 + 一小段预加载边距**的元素才建图层。
    ///
    /// 1000 个元素全建图层、全解码是这个批次最直接的开销来源，而屏幕外的元素
    /// 一个像素都看不见。这里要的数字只有两个：建了图层的元素数（远小于场景），
    /// 以及**移出视口再移回来有没有重新解码**（没有——缓存按素材共享，不按元素，
    /// 路线图 §5 把它列成必测场景）。
    private static func viewportVirtualizationKeepsLayerCountBounded() async {
        print("视口虚拟化")
        let count = 1000
        let assets = SyntheticImageProvider.makeAssets(count: 3)
        let provider = SyntheticImageProvider(assets: assets)
        let counting = CountingImageProvider(provider)

        // 1000 个元素铺成 25 列的网格，每个 200×150、间距 60——比视口大得多。
        struct Spec {
            let id: CanvasElementID
            let asset: AssetID
            let frame: CGRect
        }
        var specs: [Spec] = []
        for index in 0..<count {
            specs.append(Spec(
                id: CanvasElementID(),
                asset: assets[index % assets.count].id,
                frame: CGRect(x: CGFloat(index % 25) * 260,
                              y: CGFloat(index / 25) * 210,
                              width: 200, height: 150)
            ))
        }
        let idsInSceneOrder = specs.map(\.id)
        var live = Set(idsInSceneOrder)
        let initialScene = CanvasScene()
        func buildScene() -> CanvasScene {
            var scene = CanvasScene(boardID: initialScene.boardID)
            for (order, spec) in specs.enumerated() where live.contains(spec.id) {
                scene.insert(CanvasElement(id: spec.id, kind: .image(asset: spec.asset),
                                           frame: spec.frame, order: order))
            }
            return scene
        }
        let (coordinator, _) = makeCoordinator(scene: buildScene(), images: counting)

        // 可见集合**自己算一遍**：用相机参数和预加载边距拼出那个矩形，不读渲染器的
        // `visibleWorldRect`——那是被测方的记账。两边的矩形还必须一致，否则
        // "可见"这件事就有了两份判据（虚拟化最该防的就是这个）。
        func visibleRect() -> CGRect {
            let camera = coordinator.camera
            let margin = coordinator.motionConfiguration.viewport.preloadMargin
            let halfWidth = (camera.viewportSize.width / 2 + margin) / camera.zoom
            let halfHeight = (camera.viewportSize.height / 2 + margin) / camera.zoom
            return CGRect(x: camera.center.x - halfWidth, y: camera.center.y - halfHeight,
                          width: halfWidth * 2, height: halfHeight * 2)
        }
        func expectedVisible() -> Set<CanvasElementID> {
            let rect = visibleRect()
            return Set(specs.filter { live.contains($0.id) && $0.frame.intersects(rect) }.map(\.id))
        }

        expect(nearlyEqual(coordinator.renderedVisibleWorldRect, visibleRect()),
               "渲染器算的可见矩形与自检自己算的一致（「可见」只有一份判据）",
               detail: "渲染器 \(coordinator.renderedVisibleWorldRect)，自检 \(visibleRect())")

        let initiallyVisible = expectedVisible()
        expect(initiallyVisible.count > 0 && initiallyVisible.count < count / 20,
               "场景本身足够稀疏（不这么铺的话，这条断言验不出虚拟化）",
               detail: "1000 个元素里只有 \(initiallyVisible.count) 个在视口 + 预加载边距内")
        expect(coordinator.renderedElementIDs == initiallyVisible,
               "只有可见的元素建了图层",
               detail: "期望 \(initiallyVisible.count) 个，实际建了 \(coordinator.materializedElementCount) 个")

        let farID = idsInSceneOrder[count - 1]
        expect(coordinator.renderedFrame(of: farID) == nil,
               "屏幕外的元素连图层都没有（不是建好了再隐藏）")
        expect(coordinator.renderedImageSize(of: farID) == nil,
               "屏幕外的元素没有像素落到图层上")

        let firstVisible = idsInSceneOrder.first { initiallyVisible.contains($0) }!
        let loaded = await waitUntil("视口内的元素出图") {
            coordinator.renderedImageSize(of: firstVisible) != nil
        }
        expect(loaded, "视口内的元素出了图")
        // 等一会儿再数解码：给"多解了"留出犯错的时间。三张素材各一次——
        // 屏幕外的 99% 一个像素都没解过。
        try? await Task.sleep(nanoseconds: 150_000_000)
        expect(provider.decodeCount == assets.count,
               "解码数就是三张素材各一次（屏幕外的元素一张都没解）",
               detail: "\(provider.decodeCount) 次解码；场景 \(count) 个元素、可见 \(initiallyVisible.count) 个")

        // 平移到网格的另一头：旧的移出、新的移入。图层的建与删必须是可逆的。
        let homeCamera = coordinator.camera
        var farCamera = homeCamera
        farCamera.center = CGPoint(x: 24 * 260 + 100, y: 39 * 210 + 75)
        coordinator.camera = farCamera
        let farVisible = expectedVisible()
        expect(farVisible != initiallyVisible,
               "相机确实挪到了另一片元素上（否则这条断言验不出东西）",
               detail: "两处各 \(initiallyVisible.count) / \(farVisible.count) 个元素")
        expect(coordinator.renderedElementIDs == farVisible,
               "新视口里的元素建了图层，旧视口里的丢掉",
               detail: "实际建了 \(coordinator.materializedElementCount) 个")
        let dropped = initiallyVisible.subtracting(farVisible)
        expect(dropped.allSatisfy { coordinator.renderedFrame(of: $0) == nil },
               "移出视口的元素图层被丢掉（\(dropped.count) 个）")

        // 移回来：图层重建，但**像素不重新解码**——缓存按素材存，不按元素。
        let decodeBeforeReturn = provider.decodeCount
        coordinator.camera = homeCamera
        expect(coordinator.renderedElementIDs == initiallyVisible, "移回来的元素图层重建了")
        let reLoaded = await waitUntil("移回来之后图片重新落到图层上") {
            coordinator.renderedImageSize(of: firstVisible) != nil
        }
        expect(reLoaded, "移回来之后图片重新落到图层上")
        expect(provider.decodeCount == decodeBeforeReturn,
               "移出视口再移回来不重新解码（像素一直躺在共享缓存里）",
               detail: "移出前 \(decodeBeforeReturn) 次，移回后 \(provider.decodeCount) 次")

        // 绘制顺序：滑出去再回来的元素不许跑到最上面——那正是虚拟化会制造出来的
        // 错（图层是新建的，随手 append 就跑到最后）。断言读的是真实图层树。
        let order = coordinator.renderedElementOrder
        let positions = order.compactMap { idsInSceneOrder.firstIndex(of: $0) }
        expect(positions == positions.sorted(),
               "子层顺序仍然是场景顺序（回来的元素没有跳到最上面）",
               detail: "\(order.count) 层")

        // 不可见时被删掉的元素：模型也要跟着走。少了这一步，"移回来"会把一个已经
        // 删除的元素又显示出来——幽灵元素，而且每次删都只是"先删再显示"。
        let victim = specs[500].id
        expect(!initiallyVisible.contains(victim) && !farVisible.contains(victim),
               "守一下：挑中的元素确实不在任何一次视口里")
        live.remove(victim)
        coordinator.applySceneFromOutside(buildScene())
        var atVictim = coordinator.camera
        atVictim.center = CGPoint(x: specs[500].frame.midX, y: specs[500].frame.midY)
        coordinator.camera = atVictim
        let neighbours = expectedVisible()
        expect(!neighbours.isEmpty && !neighbours.contains(victim),
               "守一下：这个位置现在确实在视口里、旁边有别的元素、但没有被删的那个")
        expect(coordinator.renderedFrame(of: victim) == nil,
               "不可见时被删掉的元素不会在移回来的时候复活")
        expect(coordinator.renderedElementIDs == neighbours,
               "删除之后视口里的元素集合与自检算的一致",
               detail: "实际 \(coordinator.materializedElementCount) 个，期望 \(neighbours.count) 个")
    }

    /// 缓存预算、淘汰与内存压力。
    ///
    /// 这一组测的不是"缓存能不能用"（B1 已经验过账面），而是**内存吃紧时它自己
    /// 缩不缩**：缩得不够，系统会来杀；缩得过头，画布退回每帧重新解码。
    private static func imageCacheBudgetAndMemoryPressure() {
        print("缓存预算与内存压力")

        // 预算从物理内存来：1/8，夹在 64 MB ~ 512 MB 之间。
        expect(ImageCache.defaultByteBudget(physicalMemory: 64 * 1024 * 1024 * 1024)
                == ImageCache.maximumByteBudget,
               "64 GB 的机器封顶 512 MB")
        expect(ImageCache.defaultByteBudget(physicalMemory: 4 * 1024 * 1024 * 1024)
                == ImageCache.maximumByteBudget,
               "4 GB 内存的 1/8 正好是上限（512 MB）")
        expect(ImageCache.defaultByteBudget(physicalMemory: 1024 * 1024 * 1024) == 128 * 1024 * 1024,
               "1 GB 内存 → 128 MB（1/8）")
        expect(ImageCache.defaultByteBudget(physicalMemory: 128 * 1024 * 1024)
                == ImageCache.minimumByteBudget,
               "内存很小时抬到下限 64 MB（再低缓存就没意义了）")
        expect(ImageCache.defaultByteBudget() >= ImageCache.minimumByteBudget,
               "本机预算在下限之上", detail: "\(ImageCache.defaultByteBudget() / 1024 / 1024) MB")

        guard let small = makeBlankImage(CGSize(width: 1024, height: 1024)),
              let big = makeBlankImage(CGSize(width: 4096, height: 5120))
        else {
            expect(false, "造测试位图")
            return
        }
        let smallBytes = ImageCache.byteCost(of: small)
        let bigBytes = ImageCache.byteCost(of: big)

        // 峰值只能边跑边记：事后再量只能量到当时的存量。报告要的是
        // "峰值 / 稳定值 / 淘汰后值"三个数（路线图 §2.4）。
        let peak = ImageCache(byteBudget: 24 * 1024 * 1024)
        let smallAsset = AssetID(), bigAsset = AssetID()
        peak.store(small, for: smallAsset, tier: .full)
        expect(peak.peakTotalBytes == smallBytes, "存进去之后账面就是峰值")
        peak.store(big, for: bigAsset, tier: .full)
        expect(peak.peakTotalBytes == smallBytes + bigBytes,
               "峰值记的是淘汰**之前**的瞬时值（不是稳定值）",
               detail: "峰值 \(peak.peakTotalBytes / 1024 / 1024) MB，"
                   + "稳定值 \(peak.totalBytes / 1024 / 1024) MB")
        expect(peak.peakTotalBytes > peak.totalBytes,
               "守一下：这张图确实撑爆了预算，否则上面那条只是「存了多少记多少」")
        expect(peak.count == 1 && peak.peek(for: bigAsset, tier: .full) != nil,
               "单张比预算大时不把它自己淘汰掉（否则每次重绘都要重新解码）")

        // 内存压力：预算减半、再减半，以 64 MB 为底；critical 时清到底。
        let pressured = ImageCache(byteBudget: 256 * 1024 * 1024)
        pressured.store(big, for: bigAsset, tier: .full)
        expect(pressured.byteBudget == 256 * 1024 * 1024, "没有压力时预算不动")
        pressured.handle(.warning)
        expect(pressured.byteBudget == 128 * 1024 * 1024, "warning：预算减半")
        expect(pressured.totalBytes <= pressured.byteBudget, "减半之后账面在预算之内",
               detail: "\(pressured.totalBytes / 1024 / 1024) MB / "
                   + "\(pressured.byteBudget / 1024 / 1024) MB")
        pressured.handle(.warning)
        expect(pressured.byteBudget == ImageCache.minimumByteBudget,
               "再来一次 warning：减到下限 64 MB")
        expect(pressured.totalBytes > pressured.byteBudget,
               "守一下：这时账面确实还比预算大（下面两条才验得出来）",
               detail: "\(pressured.totalBytes / 1024 / 1024) MB > "
                   + "\(pressured.byteBudget / 1024 / 1024) MB")
        expect(pressured.count == 1,
               "反复减半也不会连最后一条都淘汰（宁可多占几十兆，不要每帧重解码）")
        pressured.handle(.critical)
        expect(pressured.count == 0,
               "critical：连最后一条也清掉（这时「留着一条大的」已经不是省内存了）")
        expect(pressured.pressureResponses == [.warning, .warning, .critical],
               "压力响应按收到的顺序留痕（报告要引用它）",
               detail: "\(pressured.pressureResponses)")

        // 收缩是单向的：底不能把预算**抬起来**——一个本来就比下限小的预算
        // 收到压力时，预算是不能变大的。
        let tiny = ImageCache(byteBudget: 8 * 1024 * 1024)
        tiny.handle(.warning)
        expect(tiny.byteBudget == 8 * 1024 * 1024,
               "比下限还小的预算收到压力时不会被抬到 64 MB（收缩只有一个方向）",
               detail: "\(tiny.byteBudget / 1024 / 1024) MB")

        // 真实的系统内存压力在测试里造不出来（总不能把测试机压到换页），所以
        // 能钉住的只有"事件掩码 → 级别"这个纯函数；"系统到底报没报过压力"
        // 读的是 `MemoryPressureMonitor.deliveries`，报告里要写明。
        expect(MemoryPressureMonitor.pressure(for: [.critical]) == .critical,
               "critical 掩码 → critical")
        expect(MemoryPressureMonitor.pressure(for: [.warning]) == .warning,
               "warning 掩码 → warning")
        expect(MemoryPressureMonitor.pressure(for: [.warning, .critical]) == .critical,
               "两个位同时置位时按更重的那一级")
        expect(MemoryPressureMonitor.pressure(for: [.normal]) == nil,
               "压力回到正常 → nil（「现在不紧张」不是「可以长回去了」）")
        expect(MemoryPressureMonitor.pressure(for: []) == nil, "空掩码 → nil")
        expect(ImageCache.MemoryPressure.warning.budgetScale == 0.5
                && ImageCache.MemoryPressure.critical.budgetScale == 0.25,
               "两个级别的收缩系数")
    }

    /// 像素驻留账本：**图层拿着的那份像素也是内存**（独立复审报回来的缺陷 ③）。
    ///
    /// ## 为什么这一组必须存在
    ///
    /// B2 的预算只约束 `ImageCache.entries`。可是同一张 `CGImage` 交给
    /// `layer.contents` 之后**图层自己也拿着它**——缓存把那条淘汰掉，像素一字节
    /// 都不会少。于是"预算 512 MB"在真实使用里并不成立：看过的图越多、内存越高，
    /// 而账本上一片正常。表现是**用久了机器开始换页、风扇转起来**，看不出是哪一步
    /// 出的错。
    ///
    /// 这一组是**纯账本**的断言，所以不挂 UI：直接建缓存、自己申报持有。走渲染器
    /// 那条路的话，"账本算得对不对"会和"渲染器记的对不对"缠在一起，红了不知道
    /// 该查哪一边。
    private static func imageResidencyLedger() {
        print("像素驻留账本")
        guard let image = makeBlankImage(CGSize(width: 512, height: 512)),
              let other = makeBlankImage(CGSize(width: 4096, height: 5120))
        else {
            expect(false, "造测试位图")
            return
        }
        let bytes = ImageResidency.byteCost(of: image)
        let otherBytes = ImageResidency.byteCost(of: other)
        let asset = AssetID(), otherAsset = AssetID()
        let key = ImageResidency.Key(asset: asset, tier: .full)
        let otherKey = ImageResidency.Key(asset: otherAsset, tier: .full)

        expect(bytes == image.bytesPerRow * image.height,
               "字节数按 CoreGraphics 真正分配的行宽算（不是 width × height × 4）",
               detail: "\(bytes) vs \(image.width * image.height * 4)")

        // 一张图：既在缓存里，又被一个图层拿着。
        let cache = ImageCache(byteBudget: bytes * 2)
        cache.residency.hold(key, bytes: bytes)
        cache.store(image, for: asset, tier: .full)
        expect(cache.residentBytes == bytes,
               "两边都有的**只算一次**——相加会把内存凭空算成两倍，而由此得出的"
                   + "「超预算」会让淘汰删掉本来够用的东西",
               detail: "账面 \(cache.totalBytes)，真实 \(cache.residentBytes)，"
                   + "图层拿着 \(cache.residency.heldTotalBytes)")
        expect(cache.layerOnlyBytes == 0, "还没淘汰过时，没有「只在图层里」的部分")

        // 账面清零——这正是缺陷 ③ 那个局面：缓存说"我全清了"，内存一字节没少。
        cache.removeAll()
        expect(cache.count == 0 && cache.totalBytes == 0, "缓存账面清零")
        expect(cache.residentBytes == bytes,
               "**账面清零之后真实占用不是零**——图层还拿着那 1 MB",
               detail: "真实占用 \(cache.residentBytes / 1024) KB")
        expect(cache.layerOnlyBytes == bytes,
               "「只在图层里」的那部分就是全部——B2 看不见的正是它",
               detail: "\(cache.layerOnlyBytes / 1024) KB")

        // 淘汰顺序：预算只够一张时，先丢**没人拿**的那张。
        let order = ImageCache(byteBudget: bytes + otherBytes - 1)
        order.residency.hold(key, bytes: bytes)
        order.store(image, for: asset, tier: .full)       // 被拿着，先进
        order.store(other, for: otherAsset, tier: .full)  // 没人拿，后进且**更新**
        expect(order.peek(for: otherAsset, tier: .full) == nil,
               "超预算时淘汰的是没人拿的那张（哪怕它刚存进来、按 LRU 最不该走）",
               detail: "淘汰了 \(order.evictionCount) 条")
        expect(order.peek(for: asset, tier: .full) != nil,
               "被图层拿着的那张留着——淘汰它一字节都省不下来")
        expect(order.residentBytes == bytes,
               "淘汰之后真实占用只剩被拿着的那份", detail: "\(order.residentBytes / 1024) KB")

        // 退一步：只剩被拿着的条目时，淘汰它们**也不省字节**。预算照旧超着，
        // 这不是 bug，是"淘汰顺序要分两级"的理由本身。
        let pinned = ImageCache(byteBudget: 1)
        pinned.residency.hold(key, bytes: bytes)
        pinned.store(image, for: asset, tier: .full)
        pinned.residency.hold(otherKey, bytes: otherBytes)
        pinned.store(other, for: otherAsset, tier: .full)
        expect(pinned.residentBytes == bytes + otherBytes,
               "两张都被拿着时，真实占用是两者之和（淘汰谁也腾不出空间）",
               detail: "\(pinned.residentBytes / 1024 / 1024) MB")
        expect(pinned.count == 1,
               "被拿着的条目仍然会被淘汰（留着它只会让账面好看）")

        // 账本本身不许被记坏：放手一个从没持有过的键不能把账做成负数——
        // 负数会一路传染到淘汰逻辑里，变成"预算算出来是负的、于是谁都不淘汰"。
        cache.residency.release(otherKey)
        expect(cache.residency.heldKeyCount == 1, "放手一个从没持有的键不会把账做坏")
    }

    /// 滚出视口不留全尺寸（§3.9 第 1 条），以及它的代价那一半：拖回来先糊一下。
    ///
    /// ## 这一条和上面那组的区别
    ///
    /// 上面那组验的是**账本算得对不对**，这组验的是**策略有没有真的接上**：
    /// 触发点在渲染器（只有它知道"这个元素出去了"），保留策略在缓存（只有它
    /// 知道留哪一档、留多大），中间靠 `ImageProvider.releaseOffscreenPixels` 连。
    /// 两端任何一端没接上，表现都是**内存随"看过多少张图"一直涨**——单看画面
    /// 完全正常。
    ///
    /// 代价那一半也要验：产品负责人确认的是"拖回来先糊一下"，不是"先空一下"。
    /// 少了先贴那张小图，视口边缘的来回拖动会看到一片空框闪。
    private static func offscreenPixelsAreDropped() async {
        print("视口外不留全尺寸")
        let assets = SyntheticImageProvider.makeAssets(count: 1)
        let asset = assets[0]
        // 第一张是 3840×2160：粗档（1/4，960×540）是 2.07 MB，落在 4 MB 的
        // 「便宜」线内；全尺寸是 31.6 MB，永远出局。两侧都够得着，测得出来。
        let id = CanvasElementID()
        let frame = CGRect(x: 0, y: 0, width: 400, height: 225)
        var scene = CanvasScene()
        scene.insert(CanvasElement(id: id, kind: .image(asset: asset.id), frame: frame, order: 0))

        let provider = SyntheticImageProvider(assets: assets)
        let cache = provider.cache
        let (coordinator, _) = makeCoordinator(scene: scene, images: provider)

        let coarse = LODTier(level: 2)
        let coarseSize = coarse.pixelSize(forOriginal: asset.pixelSize)

        // 先在 1× 上解出粗档。
        let gotCoarse = await waitUntil("粗档出图") {
            coordinator.renderedTier(of: id) == coarse
        }
        expect(gotCoarse, "先在 1× 上解出 1/4 档",
               detail: "得到 \(String(describing: coordinator.renderedTier(of: id)))")
        expect(cache.peek(for: asset.id, tier: coarse) != nil, "粗档进了缓存")

        // 放大到需要全尺寸，解出细档。此时缓存里两档都在。
        var zoomed = coordinator.camera
        zoomed.zoom = 4
        coordinator.camera = zoomed
        let gotFull = await waitUntil("全尺寸出图") {
            coordinator.renderedTier(of: id) == .full
        }
        expect(gotFull, "放大后解出原分辨率档")
        expect(cache.peek(for: asset.id, tier: .full) != nil, "全尺寸也在缓存里了")

        let heldBefore = provider.residency.heldKeyCount
        expect(heldBefore == 1, "此时图层只拿着一档（旧档在像素到达时已经放手）",
               detail: "拿着 \(heldBefore) 个键")
        let fullBytes = cache.entry(for: asset.id, tier: .full)?.bytes ?? 0
        expect(provider.residency.heldTotalBytes == fullBytes,
               "账本记的字节数就是那一档的字节数",
               detail: "账本 \(provider.residency.heldTotalBytes / 1024 / 1024) MB，"
                   + "缓存条目 \(fullBytes / 1024 / 1024) MB")

        // 拖出视口。
        var away = coordinator.camera
        away.center = CGPoint(x: 100_000, y: 100_000)
        coordinator.camera = away

        expect(coordinator.renderedFrame(of: id) == nil,
               "离开视口的元素连图层都没有了")
        expect(cache.peek(for: asset.id, tier: .full) == nil,
               "**全尺寸被放掉了**——这是 §3.9 第 1 条的全部要点",
               detail: "还留着 \(cache.count) 条")
        expect(cache.peek(for: asset.id, tier: coarse) != nil,
               "便宜的那一档留着（拖回来先贴它）")
        expect(cache.demotedTierCount == 1 && cache.demotedBytes > 0,
               "放掉这件事有留痕，报告里说得出省了多少",
               detail: "放掉 \(cache.demotedTierCount) 档 / \(cache.demotedBytes / 1024 / 1024) MB")
        expect(provider.residency.holdCount == provider.residency.releaseCount,
               "持有与放手配平——不配平就是账本漏了一笔，而漏一笔正是缺陷 ③ 的形态",
               detail: "持有 \(provider.residency.holdCount)、放手 \(provider.residency.releaseCount)")
        expect(provider.residency.heldKeyCount == 0,
               "离开视口后一个键都不拿着（拿着的键如果不放手，那些像素就永远"
                   + "既不被用、也不被淘汰）")

        // 拖回来：**先贴那张糊的**，再变清晰。
        var back = coordinator.camera
        back.center = CGPoint(x: frame.midX, y: frame.midY)
        coordinator.camera = back
        // 不 await：要的就是"相机写完的这一瞬间图层上是什么"。中间隔一次 await
        // 的话，目标档可能已经解完了，这条断言就永远为真、什么也验不出来。
        expect(coordinator.renderedImageSize(of: id) == coarseSize,
               "拖回来的**第一帧**贴的是缓存里那张小图（先糊一下，不是先空一下）",
               detail: "期望 \(coarseSize)，得到 \(String(describing: coordinator.renderedImageSize(of: id)))")

        let sharpened = await waitUntil("变清晰") {
            coordinator.renderedTier(of: id) == .full
        }
        expect(sharpened, "随后目标档解完，画面变清晰",
               detail: "得到 \(String(describing: coordinator.renderedTier(of: id)))")

        // 全尺寸重新拿回来之后，账本也要跟着重新记上。
        let fullKey = ImageResidency.Key(asset: asset.id, tier: .full)
        expect(provider.residency.isHeld(fullKey) && provider.residency.heldKeyCount == 1,
               "重新显示的档位重新申报了持有")

        // ## 边界：一档都不留
        //
        // 只解过全尺寸的图滚出视口时，宁可回视口空一下，也不能为了"先贴一张"
        // 把 31 MB 留在内存里——"不留全尺寸"是硬要求。
        //
        // 造这个局面：元素**大过视口**，挂载那一刻的需求就已经是全分辨率，
        // 于是缓存里从头到尾只有全尺寸这一档。这一条用新的一套协调器来跑，
        // 不复用上面那套（上面那套的缓存里已经躺着一张便宜的了）。
        let bigID = CanvasElementID()
        var bigScene = CanvasScene()
        let bigFrame = CGRect(x: 0, y: 0, width: 4000, height: 2250)
        bigScene.insert(CanvasElement(id: bigID, kind: .image(asset: asset.id),
                                      frame: bigFrame, order: 0))
        let bigProvider = SyntheticImageProvider(assets: assets)
        let bigCache = bigProvider.cache
        let (bigCoordinator, _) = makeCoordinator(scene: bigScene, images: bigProvider)
        let onlyFull = await waitUntil("只解出全尺寸") {
            bigCoordinator.renderedTier(of: bigID) == .full
        }
        expect(onlyFull, "大过视口的元素挂载即需要全分辨率档")
        expect(bigCache.count == 1, "此时缓存里只有这一档", detail: "\(bigCache.count) 条")

        bigCoordinator.camera = away
        expect(bigCache.count == 0,
               "只剩全尺寸时滚出视口 → **一档都不留**（不为了「先贴一张」留下 31 MB）",
               detail: "还留着 \(bigCache.count) 条")
        expect(bigProvider.residency.heldKeyCount == 0, "账本也跟着清干净了")
    }

    /// 取消**还没开始**的解码。
    ///
    /// 连续缩放会排出一串请求，前面几个在轮到自己之前就被后一个顶掉了。取消要
    /// 省下的正是这几个：一张 4K 解出来是几十毫秒的 CPU 和 31.6 MB 内存，而它
    /// 解出来就已经过时了。`decodeCount` 证不了这件事——取消省下的是**没发生**
    /// 的解码，没发生的事情在计数上留不下痕迹，所以另有
    /// `cancelledBeforeDecodeCount`。
    ///
    /// 边界（诚实口径）：已经进了 `CGContext` 的解码拦不住，它跑完仍然入缓存。
    /// 那条路**这一组验不到**——内层解码是同步的一段 C 调用，测试没法在中间插手；
    /// 代码上的判据是渲染器的代次比较（迟到的结果写不进图层）。
    private static func staleDecodeIsCancelled() async {
        print("取消过期的解码")
        let assets = SyntheticImageProvider.makeAssets(count: 1)
        let asset = assets[0]
        let id = CanvasElementID()
        let frame = CGRect(x: 0, y: 0, width: 400, height: 225)
        var scene = CanvasScene()
        scene.insert(CanvasElement(id: id, kind: .image(asset: asset.id), frame: frame, order: 0))
        let center = CGPoint(x: 400, y: 300)

        // 拖慢 1/4 档：挂载那一次会停在"还没开始解码"的状态上，给测试留出
        // 改相机的时间窗。
        let provider = SyntheticImageProvider(assets: assets)
        let slow = DelayedTierProvider(wrapping: provider, slowLevel: 2, delay: 0.3)
        let (coordinator, _) = makeCoordinator(scene: scene, images: slow)

        let requested = await waitUntil("挂载请求已发出（1/4 档）") {
            coordinator.requestedTier(of: id) == LODTier(level: 2)
        }
        expect(requested, "挂载时请求的是「刚好覆盖需求」的那一档",
               detail: "渲染器记的档位 \(String(describing: coordinator.requestedTier(of: id)?.level))")

        // 就在这一次解码还没开始的时候写相机（直接写，不走缓动的中间帧）。
        let zoomed = coordinator.handleMagnify(CanvasMagnifyInput(
            viewPoint: center, worldPoint: center, magnification: 3,
            phase: .changed, modifiers: .none
        ))
        expect(zoomed.zoom == 4, "放大到 4 倍", detail: "zoom \(zoomed.zoom)")

        let cancelled = await waitUntil("被顶掉的那次解码按取消处理") {
            provider.cancelledBeforeDecodeCount == 1
        }
        expect(cancelled, "被顶掉的解码在开始之前就被取消了",
               detail: "取消计数 \(provider.cancelledBeforeDecodeCount)")
        expect(provider.cache.peek(for: asset.id, tier: LODTier(level: 2)) == nil,
               "取消掉的那一档没有进缓存（它连解都没解）")

        let landed = await waitUntil("4 倍该有的像素落到图层") {
            coordinator.renderedImageSize(of: id) == CGSize(width: 3840, height: 2160)
        }
        expect(landed, "新那一档的像素落到了图层上",
               detail: "实际 \(String(describing: coordinator.renderedImageSize(of: id)))")
        expect(provider.decodeCount == 1,
               "整个过程只解了一张图（被取消的那次根本没跑）",
               detail: "解码 \(provider.decodeCount) 次")

        // 第二条路径：元素移出视口时也要取消在飞的请求。这条比上一条省得更多——
        // 上一条省的是"一档"，这条省的是"整张图"，而且对象已经不在屏幕上了。
        let leaving = SyntheticImageProvider(assets: assets)
        let slowLeaving = DelayedTierProvider(wrapping: leaving, slowLevel: 2, delay: 0.3)
        let (second, _) = makeCoordinator(scene: scene, images: slowLeaving)
        let issued = await waitUntil("第二个协调器也发出了挂载请求") {
            second.requestedTier(of: id) == LODTier(level: 2)
        }
        expect(issued, "第二个协调器发出了挂载请求")
        var away = second.camera
        away.center = CGPoint(x: 40_000, y: 40_000)
        second.camera = away
        let gone = await waitUntil("元素移出视口后图层被丢掉") {
            second.renderedFrame(of: id) == nil && second.materializedElementCount == 0
        }
        expect(gone, "元素移出视口后图层被丢掉",
               detail: "建了图层的元素数 \(second.materializedElementCount)")
        let cancelledOnExit = await waitUntil("移出视口也取消了在飞的解码") {
            leaving.cancelledBeforeDecodeCount == 1
        }
        expect(cancelledOnExit, "移出视口也取消了在飞的解码",
               detail: "取消计数 \(leaving.cancelledBeforeDecodeCount)")
        expect(leaving.decodeCount == 0,
               "屏幕外的元素一张都没解（省下的是一整张 4K 的时间）",
               detail: "解码 \(leaving.decodeCount) 次")
    }

    // MARK: - 图片失败之后的重试

    /// 图片加载失败之后**能恢复**（`BATCH_C_TASK.md` §7 第 9 条，产品负责人定的
    /// 口径是"自动退避重试 + 手动入口，两条都要"）。
    ///
    /// ## 这条断言是为独立复审报回来的缺陷 ① 建的
    ///
    /// B2 的渲染器在**发出请求时**就把"这个元素显示的是这一档"记下了。于是请求
    /// 失败之后那句话仍然成立，下一次扫描在"没变化就返回"那一句直接返回——
    /// **这个元素再也不会重试**，一直空着。合成素材永远成功，这条路径在 B2 里
    /// 一次都没走到；真实文件会失败（外置卷没挂、权限、被别的进程占着），
    /// 而且大多数是暂时性的。
    ///
    /// 四段，各钉一件事：
    /// 1. 瞬时失败**会**自动重试，重试之后图真的显示出来（缺陷 ① 的回归）
    /// 2. 一直坏的文件**不会**无限重试（到上限就停，交回给手动）
    /// 3. 手动入口在自动关掉的情况下也成立（少了这条，上面两条会把手动救回来，
    ///    手动那条即使坏了也看不出来）
    /// 4. 素材"不存在"是另一条路径：不自动重试，但手动能救回来
    private static func imageFailureRetriesAndManualReload() async {
        print("图片失败之后的重试")
        let assets = SyntheticImageProvider.makeAssets(count: 1)
        let asset = assets[0]
        let id = CanvasElementID()
        var scene = CanvasScene()
        scene.insert(CanvasElement(
            id: id,
            kind: .image(asset: asset.id),
            frame: CGRect(x: 0, y: 0, width: 400, height: 225),
            order: 0
        ))
        // 退避节奏压到毫秒级：要验的是"会不会重试、隔多久"，不是"等 0.5 秒"
        // 这件事本身。默认节奏（0.5 / 1 / 2 秒）见 `ImageRetryPolicy`。
        let quick = ImageRetryPolicy(maximumAutomaticRetries: 2, delays: [0.02, 0.02])

        // ---- 1. 瞬时失败：自动重试把它救回来 ----
        let flaky = TransientFailureProvider(
            wrapping: SyntheticImageProvider(assets: assets), failures: 1
        )
        let (coordinator, _) = makeCoordinator(scene: scene, images: flaky, retryPolicy: quick)

        let failed = await waitUntil("第一次请求失败被记下来") {
            coordinator.renderedImageFailures[id] != nil
        }
        expect(failed, "第一次请求失败被记下来",
               detail: "\(coordinator.renderedImageFailures)")
        expect(coordinator.renderedImageSize(of: id) == nil,
               "失败的那次没有把像素留在图层上（图层是空的，不是旧的）")
        expect(coordinator.showsFailurePlaceholder(id),
               "失败的元素铺的是失败底色——用户得能一眼看出它与「还没加载完」不一样")

        let recovered = await waitUntil("自动重试把图救回来了") {
            coordinator.renderedImageSize(of: id) != nil
        }
        expect(recovered, "自动重试把图救回来了",
               detail: "请求 \(flaky.requestCount) 次，失败原因 \(coordinator.renderedImageFailures)")
        expect(flaky.requestCount >= 2,
               "失败之后确实又发了一次请求（缺陷 ① 的判据就是这一条）",
               detail: "请求 \(flaky.requestCount) 次")
        expect(coordinator.renderedImageFailures[id] == nil,
               "成功之后失败原因被清掉（否则界面上会一直挂着一个已经好了的错误）",
               detail: "\(coordinator.renderedImageFailures)")
        expect(!coordinator.showsFailurePlaceholder(id),
               "成功之后失败底色撤掉了（否则图正常、底下还红着）")
        expect(!coordinator.hasBackingColor(id),
               "成功之后底色整块撤掉（透明图片的成功态不该留任何底）",
               detail: "底色还在")

        // ---- 2. 一直坏：到上限就停 ----
        let alwaysBad = TransientFailureProvider(
            wrapping: SyntheticImageProvider(assets: assets), failures: .max
        )
        let (stuck, _) = makeCoordinator(scene: scene, images: alwaysBad, retryPolicy: quick)
        _ = await waitUntil("一直坏的那张先失败一次") { stuck.renderedImageFailures[id] != nil }
        // 固定 sleep：等的是**一件不该发生的事**（第三次之后的自动重试），
        // 它没有可轮询的终点。0.3 秒是两档退避之和（0.04 秒）的七倍多。
        try? await Task.sleep(nanoseconds: 300_000_000)
        expect(alwaysBad.requestCount == 3,
               "自动重试到上限就停（1 次首发 + 2 次重试）",
               detail: "请求 \(alwaysBad.requestCount) 次")
        expect(stuck.renderedImageFailures[id] != nil,
               "失败原因还留着——界面靠它显示占位与提示，不能安静地空着")
        expect(stuck.showsFailurePlaceholder(id), "仍然铺着失败底色")

        // ---- 3. 手动入口（自动重试关掉，把这条路单独隔离出来）----
        let manualBad = TransientFailureProvider(
            wrapping: SyntheticImageProvider(assets: assets), failures: 1
        )
        let (manual, _) = makeCoordinator(scene: scene, images: manualBad, retryPolicy: .none)
        _ = await waitUntil("手动那组先失败一次") { manual.renderedImageFailures[id] != nil }
        try? await Task.sleep(nanoseconds: 150_000_000)
        expect(manualBad.requestCount == 1,
               "自动重试关掉时不再发请求（这条是下面那条的前提）",
               detail: "请求 \(manualBad.requestCount) 次")
        expect(manual.retryAllFailedImages() == 1, "手动重新加载返回重试了几个")
        let manualRecovered = await waitUntil("手动重新加载把图救回来了") {
            manual.renderedImageSize(of: id) != nil
        }
        expect(manualRecovered, "手动重新加载能把图救回来",
               detail: "请求 \(manualBad.requestCount) 次")
        expect(manual.retryAllFailedImages() == 0,
               "没有失败元素时手动入口返回 0（界面靠它决定要不要出现这个按钮）")

        // ---- 4. 素材不存在：不自动重试，但手动救得回来 ----
        let missing = MissingThenRestoredProvider(SyntheticImageProvider(assets: assets))
        let (loser, _) = makeCoordinator(scene: scene, images: missing, retryPolicy: quick)
        _ = await waitUntil("素材不存在被记下来") { loser.renderedImageFailures[id] != nil }
        // 同样等一件**不该发生**的事：素材不存在时的那次自动重试。
        try? await Task.sleep(nanoseconds: 250_000_000)
        expect(missing.requestCount == 1,
               "素材不存在时不自动重试（卷不会在几秒内挂上来，反复问磁盘没有意义）",
               detail: "请求 \(missing.requestCount) 次")
        expect(loser.renderedImageFailures[id] == "素材不存在",
               "「素材不存在」与「解码失败」是两个不同的原因，不能合并成一个 nil",
               detail: "\(loser.renderedImageFailures)")

        missing.restore()          // 用户把文件放回来了 / 卷挂上了
        loser.retryImage(for: id)  // 元素级的手动入口
        let restored = await waitUntil("手动重新加载之后图出现了") {
            loser.renderedImageSize(of: id) != nil
        }
        expect(restored, "文件回来之后，元素级的手动重新加载能把它显示出来",
               detail: "请求 \(missing.requestCount) 次，失败原因 \(loser.renderedImageFailures)")
    }

    /// 前几次请求故意以 `.failed` 收场，之后交给内层。
    ///
    /// 缺陷 ① 只能靠**会失败的提供者**测出来：合成素材永远成功，那条路径在
    /// B2 里一次都没走到过。
    @MainActor
    private final class TransientFailureProvider: ForwardingImageProvider {
        private var remainingFailures: Int
        private(set) var requestCount = 0

        init(wrapping wrapped: SyntheticImageProvider, failures: Int) {
            self.remainingFailures = failures
            super.init(wrapped)
        }

        override func image(for asset: AssetID, targetPixelSize: CGSize) async -> ImageRequestResult {
            requestCount += 1
            if remainingFailures > 0 {
                remainingFailures -= 1
                return .failed("模拟的瞬时失败")
            }
            return await super.image(for: asset, targetPixelSize: targetPixelSize)
        }
    }

    /// 素材"不见了"，直到 `restore()` 被调用。
    ///
    /// `.missing` 与 `.failed` 在渲染器里走的是**两条不同的路径**：前者是
    /// "文件不在"（自动重试不去问磁盘），后者是"这次没成"（退避重试）。
    @MainActor
    private final class MissingThenRestoredProvider: ForwardingImageProvider {
        private(set) var requestCount = 0
        private var isAvailable = false

        func restore() { isAvailable = true }

        override func image(for asset: AssetID, targetPixelSize: CGSize) async -> ImageRequestResult {
            requestCount += 1
            guard isAvailable else { return .missing }
            return await super.image(for: asset, targetPixelSize: targetPixelSize)
        }
    }

    // MARK: - 持久化（§3.1）

    /// 数据层的自检：**全组在临时目录里真实建库、真实写文件**（§3.7：
    /// 绝不碰真实 profile 数据目录）。
    ///
    /// 这一组测的不是"SQL 写得对不对"（那是 GRDB 与 SQLite 的事），而是
    /// 数据层自己立下的规矩：
    ///
    /// - **写路径只有一条**：画布改动走 `LibraryWriting`（这里走 `BoardStore`
    ///   那条产品路径），素材落盘走 `AssetStore.ingest`。测它们就是测
    ///   "重启之后东西还在"这件事本身（§3.1 的出口条件）。
    /// - **结构是自述的**：表、索引、版本、WAL 全部从库自己嘴里问出来
    ///   （`LibraryDatabase.structure()`），不是按 `Schema.swift` 里写了什么复述。
    /// - **失败不留半成品**：导入任何一步失败，落过盘的文件都要删掉。
    /// 坏库恢复（C2 §4 第 4 条，Codex 复审 P0 #1 / #2）。
    ///
    /// 这一组此前**一条断言都没有**：代码写完、编译通过、界面接好，但从没跑过
    /// 一次真正的坏库。所以这里分两半——
    ///
    /// - **判据**：`shouldQuarantine` 是"改不改名挪走用户的库"的唯一决定点，
    ///   逐种错各钉一条。分错的代价两个方向不对称，理由见 `FailureKind`。
    /// - **真拿一个坏文件走完整条路**：隔离到底发生了没有，以及同一秒里的两次
    ///   隔离会不会把一组备份拆散。
    ///
    /// 这里不 `import GRDB`（`Persistence/` 之外不许有它），所以"造一个结构升不
    /// 上去的库"造不出来——那一条只断言判据，不走端到端。
    private static func libraryRecoveryQuarantine() {
        print("坏库恢复与隔离（P0 #1 / #2）")

        // ---- 一、判据：只有确凿的损坏码才配得上"改名挪走" ----

        // 结果码写 SQLite 自己的数字（不是我们的猜测）：11 / 26 是"这份文件不是
        // 一个能用的库"，5 是"忙"。数字自己写出来，被测代码读到的才有来头。
        let corrupt: Int32 = 11
        let notADB: Int32 = 26
        let busy: Int32 = 5

        expect(DatabaseOpenError.openFailed(path: "/x", reason: "r", code: notADB).shouldQuarantine,
               "读出来不是库（NOTADB）→ 隔离")
        expect(DatabaseOpenError.openFailed(path: "/x", reason: "r", code: corrupt).shouldQuarantine,
               "库文件损坏（CORRUPT）→ 隔离")
        expect(DatabaseOpenError.migrationFailed(path: "/x", reason: "r", code: corrupt).shouldQuarantine,
               "迁移读到一半才发现损坏 → 同样隔离（发现得晚不等于不严重）")

        // 下面四条正是这次返修的重点：返修之前它们**全都会被隔离**，
        // 而隔离是不可逆的——用户看到空画布的第一反应是"我的素材被删了"。
        expect(!DatabaseOpenError.openFailed(path: "/x", reason: "r", code: busy).shouldQuarantine,
               "忙锁打不开 → 不隔离（另一个实例退出就好了，改名不可逆）")
        expect(!DatabaseOpenError.openFailed(path: "/x", reason: "r", code: nil).shouldQuarantine,
               "拿不到结果码 → 不隔离（宁可少隔离一次，人还能自己去救）")
        expect(!DatabaseOpenError.migrationFailed(path: "/x", reason: "r", code: 1).shouldQuarantine,
               "迁移的 SQL 出错 → 不隔离（库里装的是好数据，不能拿好库换空库）")
        expect(!DatabaseOpenError.directoryUnavailable(path: "/x", reason: "r").shouldQuarantine,
               "建不了目录 → 不隔离（跟库本身没关系）")

        // 「重试」按钮和「隔离」是同一个判据的两个出口，一并钉住。
        expect(DatabaseOpenError.openFailed(path: "/x", reason: "r", code: busy).isRetryable,
               "忙锁值得重试（界面上的重试按钮靠它决定出不出现）")
        expect(!DatabaseOpenError.migrationFailed(path: "/x", reason: "r", code: corrupt).isRetryable,
               "损坏不值得重试（重试一百次它还是坏的）")

        // ---- 二、真拿一个坏文件走一遍 ----

        guard let scratch = makeScratchDataDirectory("recovery") else {
            expect(false, "建得出临时数据目录")
            return
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        let manager = FileManager.default
        let fileName = LibraryDatabase.fileName
        let main = scratch.appendingPathComponent(fileName)
        // 固定时刻：组名要能预测，断言才写得成"应该是哪个名字"。
        let stamp = Date(timeIntervalSince1970: 1_760_000_000)
        let group = LibraryRecovery.timestamp(stamp)

        func writeGarbage(_ suffix: String) {
            try? Data("这根本不是 SQLite，只是一段随便写的字节".utf8)
                .write(to: scratch.appendingPathComponent(fileName + suffix))
        }
        func exists(_ name: String) -> Bool {
            manager.fileExists(atPath: scratch.appendingPathComponent(name).path)
        }

        // 第一次：只有主库在场。
        writeGarbage("")
        var first: LibraryQuarantine?
        do {
            // `outcome` 出了这个作用域就连库一起释放——池不放掉的话，
            // 文件还占着，下面第二次改名搬不动它。
            let outcome = try LibraryRecovery.open(at: scratch, now: stamp)
            first = outcome.quarantine
        } catch {
            expect(false, "坏库这条路走得通", detail: "\(error)")
            return
        }
        expect(first != nil, "坏库被隔离了（不是静默地建一个空库了事）")
        expect(first?.destination.lastPathComponent == "\(fileName).corrupt-\(group)",
               "落在带时间戳的名字下，用户能照着它把文件捞回来",
               detail: "\(first?.destination.lastPathComponent ?? "没隔离")")
        expect(first?.movedCompanions.isEmpty == true,
               "只有主库在场时只搬主库（这一条保证了下面那次是干净的两组）",
               detail: "\(first?.movedCompanions ?? [])")
        expect(first?.byteCount ?? 0 > 0, "记下了被隔离的字节数（0 字节的库和 80MB 的库含义不同）")
        expect(first?.reason.isEmpty == false, "带上了原始错误原因（用户要知道是哪一种打不开）")
        expect(manager.fileExists(atPath: main.path),
               "隔离之后原位又建了一个库（否则下次启动还是打不开）")
        expect(exists("\(fileName).corrupt-\(group)"), "第一份备份留在原地，没有被删")

        // 第二次：**同一秒**，而且这一次三个文件都在。
        //
        // 这是"一组备份不能被拆散"唯一显形的地方：主库的名字被上一组占了，
        // 于是整组要往后找 `-2`；而 `-wal` / `-shm` 的名字还是空的——
        // 三个文件各自去重的话，它俩会留在 `corrupt-<stamp>` 下，
        // 和第二组的主库分到两个不同的名字里。而"哪几个文件该放回一起"
        // 正是用户拿着备份去救数据时唯一要判断的事。
        writeGarbage("")
        writeGarbage("-wal")
        writeGarbage("-shm")
        var second: LibraryQuarantine?
        do {
            let outcome = try LibraryRecovery.open(at: scratch, now: stamp)
            second = outcome.quarantine
        } catch {
            expect(false, "同一秒的第二次隔离也走得通", detail: "\(error)")
            return
        }
        expect(second?.destination.lastPathComponent == "\(fileName).corrupt-\(group)-2",
               "同一秒的第二次隔离另起一个组名（不覆盖上一份备份）",
               detail: "\(second?.destination.lastPathComponent ?? "没隔离")")
        expect(second?.movedCompanions.count == 2,
               "同伴（-wal / -shm）跟着一起搬",
               detail: "\(second?.movedCompanions ?? [])")

        let secondGroup = "corrupt-\(group)-2"
        for (suffix, label) in [("", "主库"), ("-wal", "-wal"), ("-shm", "-shm")] {
            expect(exists("\(fileName).\(secondGroup)\(suffix)"),
                   "第二组的\(label)与同组成员共用一个组名")
        }
        expect(exists("\(fileName).corrupt-\(group)"),
               "第一份备份还在（第二次隔离没把它顶掉）")

        // ---- 三、不该隔离时，一个字节都不许动 ----

        // 目录的位置被一个文件占着 → 建不了目录 → 报错，但**什么都不改名**。
        let blocked = scratch.appendingPathComponent("not-a-directory")
        try? Data("我是一个文件，不是目录".utf8).write(to: blocked)
        do {
            _ = try LibraryRecovery.open(at: blocked, now: stamp)
            expect(false, "目录位置被文件占着时应当报错，而不是当没事发生")
        } catch {
            expect(true, "目录位置被文件占着 → 报错")
        }
        expect(manager.fileExists(atPath: blocked.path), "报错之后那个文件原样还在（没被改名、没被删）")
        let strayFiles = (try? manager.contentsOfDirectory(atPath: scratch.path))?
            .filter { $0.contains("corrupt-") } ?? []
        expect(strayFiles.count == 4,
               "整轮下来正好 4 个备份文件（第一组 1 个 + 第二组的主库与两个同伴）",
               detail: "\(strayFiles.sorted())")
    }

    private static func persistenceLayer() async {
        print("持久化（§3.1）")

        guard let scratch = makeScratchDataDirectory("persistence") else {
            expect(false, "建得出临时数据目录")
            return
        }
        defer {
            // 自检结束清理自己的临时目录。清理失败也**不报错**：临时目录里的
            // 残留会随系统清理，而"清理失败"不能把自检染红（库里没有任何用户数据）。
            try? FileManager.default.removeItem(at: scratch)
        }
        let probe = MemoryImageProbe()

        // ---- 库与结构 ----

        guard let database = try? LibraryDatabase.open(at: scratch) else {
            expect(false, "临时目录里打得出库")
            return
        }
        let journal = try? await database.journalMode()
        expect(journal?.lowercased() == "wal", "库开在 WAL 模式（读不挡写的前提）",
               detail: "实际是 \(journal ?? "读不出")")
        let structure = (try? await database.structure())
            ?? LibraryStructure(version: 0, tables: [], indexes: [], columns: [:])
        expect(structure.version == Schema.version, "库版本号是 v\(Schema.version)",
               detail: "实际是 \(structure.version)")
        expect(
            Set(structure.tables).isSuperset(of: ["board", "asset", "element"]),
            "三张表都在（board / asset / element）",
            detail: "\(structure.tables)"
        )
        expect(
            Set(structure.indexes).isSuperset(of: ["asset_added_at", "element_board_z", "element_asset"]),
            "三个索引都在",
            detail: "\(structure.indexes)"
        )
        // "相机与选中都不写库"（§7 第 6、7 条）——**没有列**就是没有藏它们的地方。
        let allColumns = structure.columns.values.flatMap { $0 }
        expect(
            !allColumns.contains(where: {
                $0.lowercased().contains("camera") || $0.lowercased().contains("selection")
            }),
            "任何表里都没有相机/选中的列（§7 第 6、7 条）"
        )

        // ---- 失败的导入：不留半成品 ----

        // 不是图片：属性读不出来之后，已经复制过去的文件必须被删掉。
        let bogus = scratch.appendingPathComponent("not-an-image.txt")
        try? Data("这不是图片".utf8).write(to: bogus)
        let bogusRecord = try? await AssetStore(database: database, root: scratch)
            .ingest(from: bogus, using: probe)
        expect(bogusRecord == nil, "不是图片的文件被拒绝")
        // 源文件读不了（导入前被移走）。
        guard let vanished = probe.writePNG(CGSize(width: 16, height: 16), to: scratch) else {
            expect(false, "造得出一份临时 PNG 素材")
            return
        }
        try? FileManager.default.removeItem(at: vanished)
        do {
            _ = try await AssetStore(database: database, root: scratch)
                .ingest(from: vanished, using: probe)
            expect(false, "源文件没了时报读不了")
        } catch AssetStore.ImportError.cannotRead {
            expect(true, "源文件没了时报读不了")
        } catch {
            expect(false, "源文件没了时报读不了", detail: "\(error)")
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: scratch.appendingPathComponent("assets"), includingPropertiesForKeys: nil
        )) ?? []
        expect(leftovers.isEmpty, "失败的导入一个文件都没留下",
               detail: "\(leftovers.map(\.lastPathComponent))")
        expect((try? await AssetStore(database: database, root: scratch).count()) == 0,
               "失败的导入一条记录都没写进库")

        // ---- 导入成功：字节、哈希、行 ----

        guard let source = probe.writePNG(CGSize(width: 48, height: 32), to: scratch) else {
            expect(false, "造得出一份临时 PNG 素材")
            return
        }
        // `now` 用**固定整秒值**而不是 `Date()`：added_at 按秒存（Double），
        // 真实时刻经 `timeIntervalSince1970` 往返会随机丢 1 ulp（约 0.24 微秒），
        // 逐位相等的断言就会间歇性红绿。整秒值在 Double 里精确可表示，往返无损。
        // 排序只关心秒级次序，这个固定值与被测行为无关。
        let record = try? await AssetStore(database: database, root: scratch)
            .ingest(from: source, using: probe, now: Date(timeIntervalSince1970: 1_700_000_000))
        expect(record != nil, "导入成功")
        if let record {
            let sourceBytes = try? Data(contentsOf: source)
            let storedBytes = try? Data(contentsOf: record.fileURL(in: scratch))
            expect(storedBytes != nil && storedBytes == sourceBytes,
                   "库里的字节与源文件逐字节一致",
                   detail: "源 \(sourceBytes?.count ?? -1) 字节，库里 \(storedBytes?.count ?? -1) 字节")
            expect(sourceBytes.map(sha256Hex) == record.contentHash,
                   "content_hash 是原字节的 SHA-256",
                   detail: "库记 \(record.contentHash)")
            expect(record.pixelSize == CGSize(width: 48, height: 32),
                   "像素尺寸按文件实际值入库",
                   detail: "\(record.pixelSize)")
            expect(record.relativePath.hasPrefix("assets/") && !record.relativePath.hasPrefix("/"),
                   "relative_path 是相对路径（库搬家不失效）",
                   detail: record.relativePath)
            expect(
                record.fileURL(in: scratch.appendingPathComponent("别处")).path
                    .hasPrefix(scratch.appendingPathComponent("别处").path),
                "文件位置随 root 走"
            )
            expect(probe.probed.contains(where: { $0.0 == record.fileURL(in: scratch) }),
                   "探针读的是库里那一份，不是源文件")
            let fetched = try? await AssetStore(database: database, root: scratch).asset(record.id)
            expect(fetched == record, "读回来还是它（asset(id:) 往返）")
            let all = (try? await AssetStore(database: database, root: scratch).allAssets()) ?? []
            expect(all == [record], "allAssets 排出来就是它一条")

            // ---- 画布与场景：BoardStore 的产品路径 → 调度器 → 库 ----

            let store = SceneStore(database: database)
            let scheduler = SceneWriteScheduler(store: store, quietPeriod: 0)
            let boardStore = BoardStore()
            boardStore.library = scheduler

            let workbench = boardStore.addBoard(named: "第一块")
            await scheduler.flush()
            var persisted = (try? await store.boards()) ?? []
            expect(persisted.count == 1 && persisted[0].name == "第一块",
                   "新建画布刷盘后就在库里（init 的默认画布不落库，只有改动才落）",
                   detail: "\(persisted.map(\.name))")
            boardStore.rename(workbench.id, to: "工作台")
            await scheduler.flush()
            persisted = (try? await store.boards()) ?? []
            expect(persisted.first?.name == "工作台", "改名走同一条路落库")

            var scene = CanvasScene(boardID: workbench.id)
            let e1 = CanvasElement(
                id: CanvasElementID(), kind: .image(asset: record.id),
                frame: CGRect(x: 10, y: 20, width: 100, height: 80), order: 0
            )
            let e2 = CanvasElement(
                id: CanvasElementID(), kind: .image(asset: record.id),
                frame: CGRect(x: 200, y: 40, width: 60, height: 60), order: 0
            )
            scene.insert(e1)
            scene.insert(e2)
            boardStore.applyScene(scene)
            await scheduler.flush()
            var restored = (try? await store.elements(in: workbench.id)) ?? []
            expect(restored.count == 2 && Set(restored.map(\.id)) == [e1.id, e2.id],
                   "插入的元素都落库",
                   detail: "\(restored.map(\.id))")
            expect(restored.map(\.id) == [e1.id, e2.id], "绘制顺序（z）恢复一致")
            expect(restored.first?.frame == e1.frame, "外框原样恢复")

            let moved = CGRect(x: 500, y: 600, width: 120, height: 90)
            scene.setFrame(moved, for: e1.id)
            scene.bringToFront([e1.id])
            boardStore.applyScene(scene)
            await scheduler.flush()
            restored = (try? await store.elements(in: workbench.id)) ?? []
            expect(restored.map(\.id) == [e2.id, e1.id], "提到最前之后顺序跟着变")
            expect(restored.first(where: { $0.id == e1.id })?.frame == moved,
                   "改过的外框落库")

            scene.remove([e1.id])
            boardStore.applyScene(scene)
            await scheduler.flush()
            restored = (try? await store.elements(in: workbench.id)) ?? []
            expect(restored.count == 1 && restored[0].id == e2.id, "移除元素落库")
            expect((try? await AssetStore(database: database, root: scratch).asset(record.id)) != nil,
                   "移除元素不删素材（路线图 §5）：还有别的元素引着，素材仍在")

            // 同一条规则的另一半：**最后一个**引用它的元素被移除时，素材仍然要留。
            // 分开测是因为"还有别的元素引着"会让素材幸存这件事与删除逻辑无关——
            // 真正的缺陷（"顺手把没引用的素材也清理掉"）只会在这半边显形。
            guard let secondSource = probe.writePNG(CGSize(width: 24, height: 24), to: scratch) else {
                expect(false, "造得出第二份临时 PNG 素材")
                return
            }
            let second = try? await AssetStore(database: database, root: scratch)
                .ingest(from: secondSource, using: probe, now: Date(timeIntervalSince1970: 1_700_000_100))
            expect(second != nil, "第二份素材导入成功")
            if let second {
                let loneBoard = boardStore.addBoard(named: "单元素")
                var loneScene = CanvasScene(boardID: loneBoard.id)
                let e4 = CanvasElement(
                    id: CanvasElementID(), kind: .image(asset: second.id),
                    frame: CGRect(x: 0, y: 0, width: 30, height: 30), order: 0
                )
                loneScene.insert(e4)
                boardStore.applyScene(loneScene)
                await scheduler.flush()
                loneScene.remove([e4.id])
                boardStore.applyScene(loneScene)
                await scheduler.flush()
                expect((try? await AssetStore(database: database, root: scratch).asset(second.id)) != nil,
                       "移除唯一引用它的元素之后，素材仍然留着（路线图 §5）")
                // 清场：后面几段都只围绕第一份素材，这里删掉第二份让计数回到 1，
                // 并删掉"单元素"画布（它的 e4 会由外键连带删）。
                try? await database.write { db in
                    try db.execute(sql: "DELETE FROM asset WHERE id = ?",
                                   arguments: [second.id.raw.uuidString])
                }
                boardStore.remove(loneBoard.id)
                await scheduler.flush()
            }

            // ---- 调度器：安静期内攒着、刷盘时合并 ----

            let batchScheduler = SceneWriteScheduler(store: store, quietPeriod: 0.2)
            let batchBoards = BoardStore()
            batchBoards.library = batchScheduler
            let batchBoard = batchBoards.boards[0]
            batchBoards.rename(batchBoard.id, to: "批")
            var batchScene = CanvasScene(boardID: batchBoard.id)
            let e3 = CanvasElement(
                id: CanvasElementID(), kind: .image(asset: record.id),
                frame: CGRect(x: 0, y: 0, width: 40, height: 40), order: 0
            )
            batchScene.insert(e3)
            batchBoards.applyScene(batchScene)
            var lastFrame = CGRect.zero
            for step in 0..<4 {
                lastFrame = CGRect(x: CGFloat(step) * 10, y: 0, width: 40, height: 40)
                batchScene.setFrame(lastFrame, for: e3.id)
                batchBoards.applyScene(batchScene)
            }
            expect(batchScheduler.submittedCount >= 5, "安静期内收下了全部变更",
                   detail: "收下 \(batchScheduler.submittedCount) 个")
            expect(batchScheduler.commitCount == 0, "安静期内什么都没写（拖动中不写）")
            await batchScheduler.flush()
            expect(batchScheduler.commitCount == 2, "刷盘时合并生效（画布 1 次 + 场景并成 1 次）",
                   detail: "提交 \(batchScheduler.commitCount) 次")
            let merged = (try? await store.elements(in: batchBoard.id)) ?? []
            expect(merged.count == 1 && merged[0].frame == lastFrame,
                   "合并之后写的是最后一次外框",
                   detail: "\(merged.first?.frame ?? .null)")

            // ---- 重开：出口条件本体（导入后重开，元素与顺序一致） ----

            guard let reopened = try? LibraryDatabase.open(at: scratch) else {
                expect(false, "同一个目录重开打得出库")
                return
            }
            let snapshot = try? await LibrarySnapshot.load(from: reopened)
            expect(snapshot?.boards.map(\.name) == ["批", "工作台"],
                   "重开后画布按 sort 恢复",
                   detail: "\(snapshot?.boards.map(\.name) ?? [])")
            expect(snapshot?.elementCount == 2, "重开后两个元素都在",
                   detail: "\(snapshot?.elementCount ?? -1) 个")
            expect(snapshot?.elements(in: workbench.id).first?.id == e2.id,
                   "工作台的元素与顺序一致（出口条件本体）")
            expect(snapshot?.elements(in: batchBoard.id).first?.frame == lastFrame,
                   "批画布的元素是合并后的最后一版")

            if let snapshot {
                let revived = BoardStore(snapshot: snapshot)
                expect(revived.boards.map(\.name) == snapshot.boards.map(\.name),
                       "BoardStore(snapshot:) 恢复画布与顺序")
                expect(
                    revived.activeScene.elements.count == snapshot.elements(in: revived.activeBoardID).count,
                    "当前画布的元素也恢复了"
                )
                expect(revived.activeCamera == .initial, "相机回初始视角（不持久化，§7 第 7 条）")
                expect(revived.activeSelection.isEmpty, "选中为空（不持久化，§7 第 6 条）")
            }

            // ---- 素材的生命周期：RESTRICT + CASCADE ----

            var deleteBlocked = false
            do {
                try await reopened.write { db in
                    try db.execute(sql: "DELETE FROM asset WHERE id = ?",
                                   arguments: [record.id.raw.uuidString])
                }
            } catch {
                deleteBlocked = true
            }
            expect(deleteBlocked, "还被元素引用的素材删不掉（外键 RESTRICT）")
            expect((try? await AssetStore(database: reopened, root: scratch).count()) == 1,
                   "删不掉时素材还在")

            try? await reopened.write { db in
                try db.execute(sql: "DELETE FROM board WHERE id = ?",
                               arguments: [batchBoard.id.uuidString])
            }
            expect((try? await store.elementCount()) == 1,
                   "删画布连带删元素（CASCADE），另一块的还在")

            deleteBlocked = false
            do {
                try await reopened.write { db in
                    try db.execute(sql: "DELETE FROM asset WHERE id = ?",
                                   arguments: [record.id.raw.uuidString])
                }
            } catch {
                deleteBlocked = true
            }
            expect(deleteBlocked, "还有一块画布引着，素材仍然删不掉")

            try? await reopened.write { db in
                try db.execute(sql: "DELETE FROM board WHERE id = ?",
                               arguments: [workbench.id.uuidString])
            }
            var deleteSucceeded = false
            do {
                try await reopened.write { db in
                    try db.execute(sql: "DELETE FROM asset WHERE id = ?",
                                   arguments: [record.id.raw.uuidString])
                }
                deleteSucceeded = true
            } catch {}
            expect(deleteSucceeded, "没有元素引用之后素材才删得掉")
            expect((try? await AssetStore(database: reopened, root: scratch).count()) == 0,
                   "库回到空素材")
        }
    }

    // MARK: - 真解码（§3.2）

    /// 真解码的自检：**在临时目录里写真实图片文件**，让 `FileImageProvider`
    /// 走完整条链路。素材全是现造的合成文件，不碰旧图库（路线图 §6）。
    ///
    /// 这一组的中心是**实测**，不是复述实现（B2 吃过"凭印象以为同构"的亏）：
    ///
    /// - 方向 6 的 JPEG 由 `CGImageDestination` 真写进 EXIF，**先独立于被测代码
    ///   直读一遍确认它在**，然后才交给 `FileImageProvider`——"我写 6、它读 6"
    ///   证不出任何事；要证的是"方向在文件里 → 探针算出对调尺寸 → 解码端摆正"。
    /// - 缩略图路径的输出尺寸、缓存条目、失败文案、取消计数全部从提供者嘴里
    ///   问出来，不是按 `FileImageProvider.swift` 里写了什么复述。
    /// - 透明通道：`CGImageDestination` 真写一张带 alpha 的 PNG，透明角落的
    ///   **像素**被读出来确认 alpha 仍是 0（"通道在"与"点真的透明"是两件事），
    ///   再接一段渲染器实测：真图到位后图层不留底色（产品负责人实测反馈的
    ///   "透明 PNG 显示成灰块"的回归）。
    private static func fileImageProvider() async {
        print("真解码（§3.2）")

        guard let scratch = makeScratchDataDirectory("file-image-provider") else {
            expect(false, "建得出临时数据目录")
            return
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        // ---- 造文件：存储 30×20、EXIF 方向 6（摆正之后 20×30）----

        guard let orientedURL = writeOrientedJPEG(width: 30, height: 20, orientation: 6, to: scratch) else {
            expect(false, "写得出带 EXIF 方向的 JPEG")
            return
        }

        // 先独立于被测代码确认：这份文件真的带着方向 6（ImageIO 直读）。
        var fileCarriesOrientation = false
        if let source = CGImageSourceCreateWithURL(orientedURL as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            fileCarriesOrientation = (properties[kCGImagePropertyOrientation] as? Int) == 6
        }
        expect(fileCarriesOrientation, "测试文件本身带着 EXIF 方向 6（实测文件，不是复述）")

        // ---- probe：摆正之后的尺寸 ----

        let probeProvider = FileImageProvider(locator: SnapshotAssetLocator(root: scratch))
        let facts = await probeProvider.probe(orientedURL)
        expect(facts?.exifOrientation == 6, "probe 报出文件里的方向值 6",
               detail: "实际 \(String(describing: facts?.exifOrientation))")
        expect(facts?.pixelSize == CGSize(width: 20, height: 30),
               "probe 返回摆正之后的尺寸（方向 5–8 宽高对调）",
               detail: "实际 \(String(describing: facts?.pixelSize))")

        // ---- 建记录与定位器，用同一个文件当素材 ----

        let orientedID = AssetID()
        let orientedBytes = (try? Data(contentsOf: orientedURL)) ?? Data()
        let orientedRecord = AssetRecord(
            id: orientedID,
            originalFilename: "oriented.jpg",
            relativePath: orientedURL.lastPathComponent,
            byteCount: orientedBytes.count,
            contentHash: sha256Hex(orientedBytes),
            pixelSize: facts?.pixelSize ?? .zero,
            exifOrientation: facts?.exifOrientation ?? 1,
            kind: .image,
            origin: .fileImport,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let locator = SnapshotAssetLocator(root: scratch, assets: [orientedRecord])
        let cache = ImageCache()
        let provider = FileImageProvider(locator: locator, cache: cache)

        // ---- metadata：与 probe 同一口径 ----

        let metadata = await provider.metadata(for: orientedID)
        expect(metadata?.pixelSize == CGSize(width: 20, height: 30),
               "metadata 是摆正之后的尺寸",
               detail: "实际 \(String(describing: metadata?.pixelSize))")

        // ---- 解码：全档（摆正由 transform 开关保证）----

        var fullDecoded: CGImage?
        switch await provider.image(for: orientedID, targetPixelSize: CGSize(width: 20, height: 30)) {
        case .image(let image):
            fullDecoded = image
        case .missing:
            expect(false, "文件在、能解码：不落 .missing")
        case .failed(let reason):
            expect(false, "文件在、能解码：不落 .failed", detail: reason)
        case .cancelled:
            expect(false, "未被取消的请求不落 .cancelled")
        }
        expect(fullDecoded?.width == 20 && fullDecoded?.height == 30,
               "方向 6 的文件解码出来是摆正的竖图（transform 开关实测钉住）",
               detail: "实际 \(fullDecoded?.width ?? 0)×\(fullDecoded?.height ?? 0)")
        expect(provider.lastDecodeWasOffMainThread == true, "解码不在主线程上跑")
        expect(provider.decodeCount == 1, "第一次解码真的发生了一次")

        // ---- 解码：半档（缩略图路径的目标尺寸约束）----

        var halfDecoded: CGImage?
        switch await provider.image(for: orientedID, targetPixelSize: CGSize(width: 10, height: 15)) {
        case .image(let image):
            halfDecoded = image
        case .missing, .failed, .cancelled:
            expect(false, "半档解码失败")
        }
        expect(halfDecoded?.width == 10 && halfDecoded?.height == 15,
               "半档解码落在目标尺寸上",
               detail: "实际 \(halfDecoded?.width ?? 0)×\(halfDecoded?.height ?? 0)")

        // ---- 缓存：两个档位两个条目，同档再来是命中 ----

        expect(cache.entry(for: orientedID, tier: .full)?.pixelSize == CGSize(width: 20, height: 30),
               "全档条目按摆正后的尺寸记账")
        expect(cache.entry(for: orientedID, tier: LODTier(level: 1))?.pixelSize == CGSize(width: 10, height: 15),
               "半档条目按目标尺寸记账")
        let again = await provider.image(for: orientedID, targetPixelSize: CGSize(width: 20, height: 30))
        guard case .image = again else {
            expect(false, "同档重取命中缓存")
            return
        }
        expect(provider.decodeCount == 2, "同档重取不再解码（缓存命中）",
               detail: "解码次数 \(provider.decodeCount)")
        let cached = provider.cachedImage(for: orientedID, atMost: .full)
        expect(cached?.tier == .full, "cachedImage 返回不比全档更细的那一张")

        // ---- 透明通道：真带 alpha 的 PNG 走完整条链路 ----
        //
        // 产品负责人实测反馈过"带透明通道的 PNG 在画布上显示成一块灰"。灰来自
        // 图层底色（画在 `contents` 后面，从透明区域透出来），但**前提是解码
        // 结果里真的还有透明**——所以两头都要钉：解码没把 alpha 压平（逐像素
        // 读），渲染器图层在真图到位后不留底色（图层实测）。

        guard let alphaURL = writeTransparentPNG(size: CGSize(width: 32, height: 24), to: scratch) else {
            expect(false, "写得出带透明通道的 PNG")
            return
        }
        // 先独立于被测代码确认：这份文件真的带 alpha（ImageIO 直读，不解码）。
        if let source = CGImageSourceCreateWithURL(alphaURL as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            expect((properties[kCGImagePropertyHasAlpha] as? Bool) == true,
                   "测试文件本身带透明通道（实测文件，不是复述）")
        } else {
            expect(false, "读得出测试文件的属性")
        }

        let alphaID = AssetID()
        let alphaBytes = (try? Data(contentsOf: alphaURL)) ?? Data()
        let alphaRecord = AssetRecord(
            id: alphaID,
            originalFilename: "transparent.png",
            relativePath: alphaURL.lastPathComponent,
            byteCount: alphaBytes.count,
            contentHash: sha256Hex(alphaBytes),
            pixelSize: CGSize(width: 32, height: 24),
            exifOrientation: 1,
            kind: .image,
            origin: .fileImport,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let alphaProvider = FileImageProvider(
            locator: SnapshotAssetLocator(root: scratch, assets: [alphaRecord]),
            cache: ImageCache()
        )

        var alphaFull: CGImage?
        switch await alphaProvider.image(for: alphaID, targetPixelSize: CGSize(width: 32, height: 24)) {
        case .image(let image):
            alphaFull = image
        case .missing, .failed, .cancelled:
            expect(false, "带 alpha 的 PNG 能解码")
        }
        if let alphaFull {
            // 逐像素读：`alphaInfo` 只说"有没有这个通道"，像素才说"通道里是什么"。
            let corner = pixelRGBA(of: alphaFull, at: CGPoint(x: 2, y: 2))
            expect(corner?.a == 0, "透明角落在解码结果里 alpha 仍是 0（没被压平成实色）",
                   detail: "读到 rgba \(String(describing: corner))")
            let center = pixelRGBA(of: alphaFull, at: CGPoint(x: 16, y: 12))
            expect(center?.a == 255, "不透明区域没有被误伤",
                   detail: "读到 rgba \(String(describing: center))")
        } else {
            expect(false, "解码结果可读像素")
        }

        // 缩略图路径（`CreateThumbnailAtIndex`）同样不许压平 alpha。
        var alphaThumb: CGImage?
        switch await alphaProvider.image(for: alphaID, targetPixelSize: CGSize(width: 16, height: 12)) {
        case .image(let image):
            alphaThumb = image
        case .missing, .failed, .cancelled:
            expect(false, "带 alpha 的 PNG 缩略图档能解码")
        }
        if let alphaThumb {
            let corner = pixelRGBA(of: alphaThumb, at: CGPoint(x: 1, y: 1))
            expect(corner?.a == 0, "缩略图路径同样保住透明",
                   detail: "读到 rgba \(String(describing: corner))")
        } else {
            expect(false, "缩略图解码结果可读像素")
        }

        // ---- 渲染器：真图到位后图层不留底色（实测反馈的回归）----
        //
        // 两段：**冷缓存**走 `finish`（真解码落到图层），**拖出再拖回**走缓存
        // 种子那条路（`requestImage` 里先贴小图的那一句）。两条路都得清掉底色
        // ——只清一条的话，另一条依然会亮出一块灰。

        let alphaElementID = CanvasElementID()
        var alphaScene = CanvasScene()
        alphaScene.insert(CanvasElement(
            id: alphaElementID,
            kind: .image(asset: alphaID),
            frame: CGRect(x: 0, y: 0, width: 128, height: 96),
            order: 0
        ))
        // 冷缓存：上面两次直接解码用的是另一个 provider，这一套必须自己解一次，
        // 断言才算落在 `finish` 那条路上（种子路径由下面一段专门钉）。
        let coldProvider = FileImageProvider(
            locator: SnapshotAssetLocator(root: scratch, assets: [alphaRecord]),
            cache: ImageCache()
        )
        let (alphaCoordinator, _) = makeCoordinator(scene: alphaScene, images: coldProvider)
        let alphaLoaded = await waitUntil("透明素材的像素进了图层") {
            alphaCoordinator.renderedImageSize(of: alphaElementID) != nil
        }
        expect(alphaLoaded, "透明素材的像素真的进了图层",
               detail: "失败原因 \(alphaCoordinator.renderedImageFailures)")
        expect(!alphaCoordinator.hasBackingColor(alphaElementID),
               "真解码落到图层之后没有底色（有它就是用户看到的那块灰）",
               detail: "图层仍留着底色")

        // 拖出视口再拖回：第一帧贴的是缓存里那张小图（种子路径）。
        var away = alphaCoordinator.camera
        away.center = CGPoint(x: 100_000, y: 100_000)
        alphaCoordinator.camera = away
        var back = alphaCoordinator.camera
        back.center = CGPoint(x: 64, y: 48)
        alphaCoordinator.camera = back
        // 不 await：要的就是"相机写完的这一瞬间图层上是什么"——隔一次 await，
        // 目标档可能已经解完，断言就变成在验另一条路了。
        expect(alphaCoordinator.renderedImageSize(of: alphaElementID) != nil,
               "拖回来第一帧贴上了缓存里的图（下面那条断言的前提）",
               detail: "第一帧图层还是空的")
        expect(!alphaCoordinator.hasBackingColor(alphaElementID),
               "种子路径同样不留底色（只清一条路的话，另一条依然亮一块灰）")

        // ---- .missing：库里没有 / 文件被删 ----

        if case .missing = await provider.image(for: AssetID(), targetPixelSize: CGSize(width: 10, height: 10)) {
            expect(true, "定位器里没有的素材 → .missing")
        } else {
            expect(false, "定位器里没有的素材 → .missing")
        }

        let memoryProbe = MemoryImageProbe()
        guard let plainURL = memoryProbe.writePNG(CGSize(width: 48, height: 32), to: scratch) else {
            expect(false, "写得出普通 PNG")
            return
        }
        let deletedID = AssetID()
        let deletedRecord = AssetRecord(
            id: deletedID,
            originalFilename: "deleted.png",
            relativePath: plainURL.lastPathComponent,
            byteCount: 0,
            contentHash: "",
            pixelSize: CGSize(width: 48, height: 32),
            exifOrientation: 1,
            kind: .image,
            origin: .fileImport,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let deletedLocator = SnapshotAssetLocator(root: scratch, assets: [deletedRecord])
        let deletedProvider = FileImageProvider(locator: deletedLocator)
        guard case .image = await deletedProvider.image(for: deletedID, targetPixelSize: CGSize(width: 48, height: 32)) else {
            expect(false, "文件还在时能解码（删掉之前的对照）")
            return
        }
        try? FileManager.default.removeItem(at: plainURL)
        switch await deletedProvider.image(for: deletedID, targetPixelSize: CGSize(width: 48, height: 32)) {
        case .missing:
            expect(true, "文件被删之后 → .missing（不静默删元素，§3.5）")
        case .image:
            expect(false, "文件被删之后 → .missing")
        case .failed(let reason):
            expect(false, "文件被删之后 → .missing", detail: reason)
        case .cancelled:
            expect(false, "文件被删之后 → .missing")
        }

        // ---- .failed：文件在但不是图片，文案统一 ----

        let fakeURL = scratch.appendingPathComponent("fake.png")
        try? Data("这不是一张图片".utf8).write(to: fakeURL)
        let fakeID = AssetID()
        let fakeRecord = AssetRecord(
            id: fakeID,
            originalFilename: "fake.png",
            relativePath: fakeURL.lastPathComponent,
            byteCount: 0,
            contentHash: "",
            pixelSize: .zero,
            exifOrientation: 1,
            kind: .image,
            origin: .fileImport,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let fakeLocator = SnapshotAssetLocator(root: scratch, assets: [fakeRecord])
        let fakeProvider = FileImageProvider(locator: fakeLocator)
        expect(await fakeProvider.metadata(for: fakeID) == nil, "读不出属性的文件 metadata 是 nil")
        expect(await fakeProvider.probe(fakeURL) == nil, "读不出属性的文件 probe 是 nil")
        switch await fakeProvider.image(for: fakeID, targetPixelSize: CGSize(width: 48, height: 32)) {
        case .failed(let reason):
            expect(reason == "这个文件不是能解码的图片", "失败文案统一（§3.2）", detail: reason)
        case .image:
            expect(false, "不是图片 → .failed")
        case .missing:
            expect(false, "文件在但不是图片：不落 .missing")
        case .cancelled:
            expect(false, "不是图片 → .failed")
        }

        // ---- .cancelled：解码开始之前就取消 ----

        // 任务体在取消之后才开始跑：cancel() 与创建在同一个主 actor 回合，
        // 任务体只能排在下一回合，所以判据一定先于解码成立。
        let cancelledRequest = Task { @MainActor in
            await provider.image(for: orientedID, targetPixelSize: CGSize(width: 5, height: 7))
        }
        cancelledRequest.cancel()
        switch await cancelledRequest.value {
        case .cancelled:
            expect(true, "开始前就被取消的请求 → .cancelled")
        case .image:
            expect(false, "开始前就被取消的请求 → .cancelled")
        case .missing, .failed:
            expect(false, "开始前就被取消的请求 → .cancelled")
        }
        expect(provider.cancelledBeforeDecodeCount == 1, "取消发生在解码之前（真的省下了一次解码）",
               detail: "取消计数 \(provider.cancelledBeforeDecodeCount)")

        // ---- inFlight 合并：并发同档只解一次 ----

        let dedupProvider = FileImageProvider(locator: locator, cache: ImageCache())
        async let first = dedupProvider.image(for: orientedID, targetPixelSize: CGSize(width: 20, height: 30))
        async let second = dedupProvider.image(for: orientedID, targetPixelSize: CGSize(width: 20, height: 30))
        let (dedupA, dedupB) = await (first, second)
        guard case .image = dedupA, case .image = dedupB else {
            expect(false, "并发同档请求都拿到图")
            return
        }
        expect(dedupProvider.decodeCount == 1, "并发同档只解码一次（inFlight 合并）",
               detail: "解码次数 \(dedupProvider.decodeCount)")

        // ---- 导入链路：FileImageProvider 当探针（§3.2 接 §3.3）----

        guard let database = try? LibraryDatabase.open(at: scratch) else {
            expect(false, "临时目录里打得出库")
            return
        }
        let store = AssetStore(database: database, root: scratch)
        guard let imported = try? await store.ingest(from: orientedURL, using: provider) else {
            expect(false, "导入带方向的 JPEG 成功")
            return
        }
        expect(imported.pixelSize == CGSize(width: 20, height: 30),
               "导入落库的尺寸是摆正之后的",
               detail: "实际 \(imported.pixelSize)")
        expect(imported.exifOrientation == 6, "导入落库的方向值是文件里的原始值")
        let storedBytes = try? Data(contentsOf: imported.fileURL(in: scratch))
        expect(storedBytes.map(sha256Hex) == sha256Hex(orientedBytes),
               "导入复制的是原字节（不转码）")
    }

    /// 建一个自检专用的临时数据目录。
    ///
    /// 持久化断言要**真实建库、真实写文件**，落点必须是系统临时目录
    /// （§3.7：全部在临时目录跑，绝不碰真实 profile 数据目录）。
    /// §3.3：采集第一条通道——本地导入。
    ///
    /// 断言覆盖三块：政策（§3.9 第 2、3 条的上限，超限拒绝发生在复制之前）、
    /// 流水线（入库 → 定位表 → 画布网格落点），以及"失败不留半成品"（§5）。
    /// 网格落点是纯几何，这里直接跑"批大小 × 相机"的组合对答案，不靠读画布。
    private static func importCoordinator() async {
        print("采集通道（§3.3）")

        guard let scratch = makeScratchDataDirectory("import") else {
            expect(false, "建得出临时数据目录")
            return
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard let database = try? LibraryDatabase.open(at: scratch) else {
            expect(false, "临时目录里打得出库")
            return
        }
        let store = AssetStore(database: database, root: scratch)
        let locator = SnapshotAssetLocator(root: scratch)
        let provider = FileImageProvider(locator: locator)
        let probe = MemoryImageProbe()

        func assetFileCount() -> Int {
            let directory = scratch.appendingPathComponent("assets")
            guard let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: nil
            ) else { return 0 }
            var count = 0
            while enumerator.nextObject() != nil { count += 1 }
            return count
        }

        // ---- 单文件导入：入库 → 定位表 → 画布居中 ----

        let boardsA = BoardStore()
        let coordinatorA = ImportCoordinator(
            store: store, prober: provider, boards: boardsA, locator: locator
        )
        guard let plain = probe.writePNG(CGSize(width: 48, height: 32), to: scratch) else {
            expect(false, "写得出普通 PNG")
            return
        }
        let sourceBytes = (try? Data(contentsOf: plain)) ?? Data()
        let outcomesA = await coordinatorA.importFiles([plain])
        guard case .imported(let record) = outcomesA[plain] else {
            expect(false, "单文件导入成功", detail: outcomesA[plain]?.message ?? "无结果")
            return
        }
        expect(record.originalFilename == plain.lastPathComponent, "库里记的是原文件名")
        expect(record.relativePath == AssetStore.relativePath(for: record.id, extension: "png"),
               "落点符合 assets/<前两位>/<uuid> 规则")
        expect(record.byteCount == sourceBytes.count, "字节数与源文件一致")
        expect(record.contentHash == sha256Hex(sourceBytes), "哈希是原字节的 SHA-256")
        expect(record.pixelSize == CGSize(width: 48, height: 32), "尺寸来自文件头")
        expect(record.exifOrientation == 1, "无 EXIF 方向按 1 记")
        expect(record.origin == .fileImport, "C1 通道的来源是 fileImport")
        // 定位表立刻装好：解码路径不等重启（重启前显示不出的那类"像缓存问题"）
        guard case .image(let decoded) = await provider.image(
            for: record.id, targetPixelSize: record.pixelSize
        ) else {
            expect(false, "导入完立刻能经真提供者解码（定位表已装）")
            return
        }
        expect(decoded.width == 48 && decoded.height == 32, "解码出来是原尺寸")
        let copied = try? Data(contentsOf: store.root.appendingPathComponent(record.relativePath))
        expect(copied == sourceBytes, "落盘字节与原文件一致（复制原字节，不转码）")
        expect((try? await store.count()) == 1, "库里正好一条素材")
        // 画布：一个元素，居中于视口中心。相机 .initial：中心 (0,0)、视口 800×600、
        // 缩放 1 → 单元格 240×180；单张的列数收敛为 1，正好落在视口中心。
        let elementsA = boardsA.activeScene.elements
        expect(elementsA.count == 1, "画布上多了一个元素")
        guard let elementA = elementsA.first else { return }
        expect(elementA.kind == .image(asset: record.id), "元素引用刚入库的素材")
        expect(
            nearlyEqual(elementA.frame.midX, 0) && nearlyEqual(elementA.frame.midY, 0),
            "单张导入居中于视口中心",
            detail: "中心是 (\(elementA.frame.midX), \(elementA.frame.midY))"
        )
        expect(
            nearlyEqual(elementA.frame.width / elementA.frame.height, 1.5, tolerance: 1e-3),
            "外框保持原图比例（48:32）"
        )

        // ---- 连续导入：按网格排在视口中心区域 ----

        let boardsB = BoardStore()
        let coordinatorB = ImportCoordinator(
            store: store, prober: provider, boards: boardsB, locator: locator
        )
        let batchSizes = [
            CGSize(width: 48, height: 32),
            CGSize(width: 32, height: 48),
            CGSize(width: 40, height: 40),
        ]
        let urlsB = batchSizes.compactMap { probe.writePNG($0, to: scratch) }
        expect(urlsB.count == 3, "三份素材都写得出")
        let outcomesB = await coordinatorB.importFiles(urlsB)
        expect(outcomesB.values.allSatisfy(\.isImported), "一批三个全部导入")
        let elementsB = boardsB.activeScene.elements
        expect(elementsB.count == 3, "三个元素都上了画布")
        expect(elementsB.map(\.order) == [0, 1, 2], "绘制顺序按导入先后")
        // 网格 3 列 1 行：单元格 240×180、间距 32 → 列中心 −272 / 0 / +272，行中心 0
        let centersB = elementsB
            .map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
            .sorted { $0.x < $1.x }
        expect(
            centersB.count == 3
                && nearlyEqual(centersB[0].x, -272)
                && nearlyEqual(centersB[1].x, 0)
                && nearlyEqual(centersB[2].x, 272),
            "网格列中心在 −272 / 0 / +272",
            detail: "\(centersB)"
        )
        expect(centersB.allSatisfy { nearlyEqual($0.y, 0) }, "单行网格的行中心在视口中心")
        let framesB = elementsB.map(\.frame)
        let overlappingB = framesB.indices.contains { i in
            framesB.indices.contains { j in j > i && framesB[i].intersects(framesB[j]) }
        }
        expect(!overlappingB, "网格内互不重叠")

        // 四个一批 → 两行：第 4 个落在第二行第一列（−272, +106）
        let boardsC = BoardStore()
        let coordinatorC = ImportCoordinator(
            store: store, prober: provider, boards: boardsC, locator: locator
        )
        let urlsC = (batchSizes + [CGSize(width: 40, height: 20)])
            .compactMap { probe.writePNG($0, to: scratch) }
        expect(urlsC.count == 4, "四份素材都写得出")
        _ = await coordinatorC.importFiles(urlsC)
        let elementsC = boardsC.activeScene.elements
        expect(elementsC.count == 4, "四个元素都上了画布")
        let secondRow = elementsC.filter { abs($0.frame.midY - 106) < 1e-6 }
        expect(secondRow.count == 1, "第二行只有第 4 个（不完整的行）")
        expect(
            secondRow.first.map { nearlyEqual($0.frame.midX, -272) } == true,
            "第 4 个落在第二行第一列",
            detail: "中心是 \(secondRow.first.map { "(\($0.frame.midX), \($0.frame.midY))" } ?? "无")"
        )

        // ---- 相机不在原点、缩放 2：网格跟着视口中心走，单元格随缩放收缩 ----

        let boardsD = BoardStore()
        boardsD.activeCamera = CanvasCamera(
            center: CGPoint(x: 100, y: 200),
            zoom: 2,
            viewportSize: CGSize(width: 800, height: 600)
        )
        let coordinatorD = ImportCoordinator(
            store: store, prober: provider, boards: boardsD, locator: locator
        )
        guard let single = probe.writePNG(CGSize(width: 48, height: 32), to: scratch) else { return }
        guard case .imported = await coordinatorD.importFiles([single])[single] else {
            expect(false, "偏移相机下也导入成功")
            return
        }
        guard let elementD = boardsD.activeScene.elements.first else {
            expect(false, "元素上了画布")
            return
        }
        expect(
            nearlyEqual(elementD.frame.midX, 100) && nearlyEqual(elementD.frame.midY, 200),
            "网格锚在视口中心（相机中心）"
        )
        // 世界视口 400×300 → 单元格 120×90；48:32 图放进去 → 120×80
        expect(
            nearlyEqual(elementD.frame.width, 120) && nearlyEqual(elementD.frame.height, 80),
            "单元格随缩放收缩",
            detail: "外框是 \(elementD.frame.width)×\(elementD.frame.height)"
        )

        // ---- §3.9 第 2 条：超限在复制之前拒绝，不留半成品 ----

        let tinyPolicy = ImportPolicy(maxLongestEdge: 64, maxTotalPixels: 10_000)
        let boardsE = BoardStore()
        let coordinatorE = ImportCoordinator(
            store: store, prober: provider, boards: boardsE, locator: locator,
            policy: tinyPolicy
        )
        let countBefore = (try? await store.count()) ?? -1
        let filesBefore = assetFileCount()
        guard let oversized = probe.writePNG(CGSize(width: 96, height: 64), to: scratch) else { return }
        let outcomeE = await coordinatorE.importFiles([oversized])[oversized]
        expect(outcomeE == .rejected(.tooLarge), "最长边超限被拒（96 > 64）")
        expect(outcomeE?.message == ImportPolicy.tooLargeMessage, "拒绝文案是「这张图太大」")
        let countAfter = try? await store.count()
        expect(countAfter == countBefore, "被拒的素材没有入库",
               detail: "前后 \(countBefore) → \(countAfter ?? -1)")
        expect(assetFileCount() == filesBefore, "被拒的素材没有落盘（§5 不留半成品）")
        expect(boardsE.activeScene.elements.isEmpty, "被拒的素材没有上画布")
        // 上限是边界不是一刀切：限内的小图照常进来
        guard let within = probe.writePNG(CGSize(width: 40, height: 20), to: scratch) else { return }
        switch await coordinatorE.importFiles([within])[within] {
        case .imported:
            expect(true, "限内的小图照常导入")
        case .storedWithoutCanvasSave:
            expect(false, "限内的小图照常导入", detail: "导入协调器不负责保存回执")
        case .rejected(let rejection):
            expect(false, "限内的小图照常导入", detail: rejection.message)
        case nil:
            expect(false, "限内的小图照常导入", detail: "无结果")
        }
        // 不是图片：统一文案（§3.2 共用那句）
        let bogus = scratch.appendingPathComponent("not-an-image.txt")
        try? Data("这不是图片".utf8).write(to: bogus)
        let outcomeF = await coordinatorE.importFiles([bogus])[bogus]
        expect(
            outcomeF == .rejected(.failed(FileImageProvider.unifiedDecodeFailure)),
            "不是图片 → 统一失败文案",
            detail: outcomeF?.message ?? "无结果"
        )
        expect(
            FileImageProvider.unifiedDecodeFailure == "这个文件不是能解码的图片",
            "统一文案是定稿那句（字面钉住，不引用常量自己）"
        )

        // ---- 政策的默认数（§3.9 定的口径，改一个数就能调） ----

        let defaultPolicy = ImportPolicy()
        expect(!defaultPolicy.rejects(CGSize(width: 40_000, height: 10)), "最长边 40000 恰在上限内")
        expect(defaultPolicy.rejects(CGSize(width: 40_001, height: 10)), "最长边 40001 被拒")
        expect(!defaultPolicy.rejects(CGSize(width: 20_000, height: 10_000)), "总像素 2 亿恰在上限内")
        expect(defaultPolicy.rejects(CGSize(width: 20_000, height: 10_001)), "总像素超 2 亿被拒")
        expect(ImportPolicy.tooLargeMessage == "这张图太大", "拒绝文案集中定义")

        // ---- §3.9 第 3 条：单次解码上限收在档位阶梯里 ----

        let decodePolicy = DecodePolicy()
        expect(
            decodePolicy.maximumTier(forOriginal: CGSize(width: 8000, height: 8000)) == .full,
            "64 MP 整 → 全档"
        )
        expect(
            decodePolicy.maximumTier(forOriginal: CGSize(width: 8000, height: 8001))
                == LODTier(level: 1),
            "超 64 MP → 最细档降到 1/2"
        )
        let huge = CGSize(width: 8000, height: 8001)
        expect(
            LODTier.settled(huge, original: huge, from: nil, headroom: 1) == LODTier(level: 1),
            "选档结果不越过解码上限"
        )
        expect(
            LODTier.settled(huge, original: huge, from: .full, headroom: 1) == LODTier(level: 1),
            "从全档出发的迟滞同样被上限夹住"
        )
        // 小上限注入实测：请求全档，真文件解码被夹到 ≤ 上限的档位
        let cappedProvider = FileImageProvider(
            locator: locator, decodePolicy: DecodePolicy(maxDecodedPixels: 100)
        )
        guard let capFile = probe.writePNG(CGSize(width: 48, height: 32), to: scratch) else { return }
        guard let capRecord = try? await store.ingest(from: capFile, using: provider) else {
            expect(false, "上限素材入库")
            return
        }
        locator.insert(capRecord)
        guard case .image(let cappedImage) = await cappedProvider.image(
            for: capRecord.id, targetPixelSize: capRecord.pixelSize
        ) else {
            expect(false, "上限内的档位解码成功")
            return
        }
        expect(
            cappedImage.width == 12 && cappedImage.height == 8,
            "48×32 配上限 100px 的全档请求 → 解码 12×8（96px）",
            detail: "得到 \(cappedImage.width)×\(cappedImage.height)"
        )

        // ---- 元素差异落库（§3.5 重启恢复的凭据） ----

        let writer = SceneWriteScheduler(store: SceneStore(database: database))
        let boardsP = BoardStore()
        boardsP.library = writer
        let coordinatorP = ImportCoordinator(
            store: store, prober: provider, boards: boardsP, locator: locator
        )
        writer.persist(board: boardsP.activeBoard, sort: 0)
        guard let lastURL = probe.writePNG(CGSize(width: 16, height: 16), to: scratch) else { return }
        guard case .imported = await coordinatorP.importFiles([lastURL])[lastURL] else {
            expect(false, "接落库调度器时导入成功")
            return
        }
        await writer.flush()
        let elementRows = try? await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM element") ?? 0
        }
        expect(elementRows == 1, "元素差异已落库（重启后恢复的凭据）", detail: "\(elementRows ?? -1) 条")

        // ---- WorkspaceModel 的对外入口：计数、刷盘、未就绪时报得出失败 ----

        guard let modelScratch = makeScratchDataDirectory("import-model") else {
            expect(false, "建得出模型场景的临时目录")
            return
        }
        defer { try? FileManager.default.removeItem(at: modelScratch) }
        let modelEnvironment = AppEnvironment(profile: .cc, dataDirectory: modelScratch)
        guard let modelFile = probe.writePNG(CGSize(width: 20, height: 20), to: modelScratch) else { return }

        let unprepared = WorkspaceModel(environment: modelEnvironment)
        let unpreparedOutcomes = await unprepared.importFiles([modelFile])
        expect(
            unpreparedOutcomes[modelFile] == .rejected(.failed("素材库没准备好：未知原因")),
            "素材库没准备好时报得出失败（不安静地空着）"
        )

        let model = WorkspaceModel(environment: modelEnvironment)
        model.prepareStorage()
        expect(model.storageError == nil, "模型场景里库开得出")
        let premature = await model.importFiles([modelFile])
        expect(premature[modelFile] == .rejected(.failed("素材库没准备好：素材库仍在恢复中")),
               "恢复画布前不能导入，避免元素外键写失败")
        // 真实启动顺序：先恢复（空库时把默认画布落库），再允许导入——
        // 元素写库有外键，画布行不在库里时导入会写失败。
        await model.restore()
        let modelOutcomes = await model.importFiles([modelFile])
        expect(modelOutcomes[modelFile]?.isImported == true, "模型的导入入口导入成功")
        expect(model.snapshotAssetCount == 1, "面板计数跟着导入走")
        expect(model.storageError == nil, "导入全程没有写库失败")
        let snapshot = try? await LibrarySnapshot.load(from: model.library!)
        expect(snapshot?.assets.count == 1, "重启等价：快照里有一条素材")
        expect(snapshot?.elementCount == 1, "重启等价：快照里有一个元素")

        // The picker accepts any file; ImageIO, not the extension, decides.
        if let bytes = try? Data(contentsOf: modelFile) {
            let misnamed = modelScratch.appendingPathComponent("valid-image.txt")
            let extensionless = modelScratch.appendingPathComponent("valid-image")
            try? bytes.write(to: misnamed)
            try? bytes.write(to: extensionless)
            let renamedOutcomes = await model.importFiles(
                [misnamed, extensionless], placingOnCanvas: false
            )
            expect(renamedOutcomes[misnamed]?.isImported == true,
                   "PNG 字节即使扩展名为 txt 也能导入")
            expect(renamedOutcomes[extensionless]?.isImported == true,
                   "PNG 字节即使无扩展名也能导入")
        } else {
            expect(false, "读得出格式回归用的 PNG 字节")
        }
    }

    /// Storage failure must not turn a material-library success into a false
    /// canvas success, and Retry must keep the queued scene job intact.
    private static func storageRetryAndImportReceipt() async {
        print("存储重试与导入回执")
        guard let scratch = makeScratchDataDirectory("storage-retry") else {
            expect(false, "建得出重试测试的临时目录")
            return
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        let blocked = scratch.appendingPathComponent("blocked")
        try? Data("not a directory".utf8).write(to: blocked)
        let initiallyBlocked = WorkspaceModel(
            environment: AppEnvironment(profile: .codex, dataDirectory: blocked)
        )
        await initiallyBlocked.recoverStorage()
        expect(initiallyBlocked.writer == nil && initiallyBlocked.storageError != nil,
               "首次打开失败会显示错误，不会建虚假的写入器")
        try? FileManager.default.removeItem(at: blocked)
        await initiallyBlocked.recoverStorage()
        let recoveredBoardCount = try? await SceneStore(database: initiallyBlocked.library!).boardCount()
        expect(recoveredBoardCount == 1 && initiallyBlocked.storageError == nil,
               "首次打开重试成功后会恢复并落下默认画布")

        let environment = AppEnvironment(profile: .codex, dataDirectory: scratch.appendingPathComponent("work"))
        let model = WorkspaceModel(environment: environment)
        await model.recoverStorage()
        guard let database = model.library, let writer = model.writer else {
            expect(false, "正常临时库准备成功")
            return
        }
        let probe = MemoryImageProbe()
        guard let image = probe.writePNG(CGSize(width: 32, height: 24), to: scratch) else {
            expect(false, "造得出导入测试图片")
            return
        }
        do {
            try await database.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER fail_canvas_insert BEFORE INSERT ON element
                    BEGIN SELECT RAISE(ABORT, 'injected canvas write failure'); END
                    """)
            }
        } catch {
            expect(false, "装得上仅测试库使用的失败触发器", detail: "\(error)")
            return
        }
        let outcome = await model.importFiles([image])[image]
        guard case .storedWithoutCanvasSave(let record, _) = outcome else {
            expect(false, "画布写失败不报已导入", detail: outcome?.message ?? "无结果")
            return
        }
        expect(record.fileURL(in: environment.dataDirectory).path.hasPrefix(environment.dataDirectory.path),
               "失败时原始图片仍安全留在素材库")
        expect((try? await SceneStore(database: database).elementCount()) == 0,
               "失败时库里不谎称已经保存画布元素")
        expect(model.writer === writer && writer.requeueCount > 0,
               "失败的写入留在原调度器里等待重试")
        expect(ImportFeedback.summary(of: [image: outcome!], orderedBy: [image])
               == .canvasSaveFailed(stored: 1, rejected: 0,
                                    reason: model.storageError!.replacingOccurrences(of: "保存失败：", with: "")),
               "用户回执明确区分素材已存与画布未存")
        do {
            try await database.write { db in try db.execute(sql: "DROP TRIGGER fail_canvas_insert") }
        } catch {
            expect(false, "移得掉测试库的失败触发器", detail: "\(error)")
            return
        }
        await model.recoverStorage()
        expect(model.writer === writer && model.storageError == nil,
               "重试复用原调度器并清除保存错误")
        let reopened = try? LibraryDatabase.open(at: environment.dataDirectory)
        var elementCount: Int?
        if let reopened { elementCount = try? await SceneStore(database: reopened).elementCount() }
        expect(elementCount == 1, "重试后重新打开仍能读到画布图片")
    }

    // MARK: - 粘贴（§4 第 2 条）

    /// 剪贴板那条通道：分类、归一、落盘、入库、摆画布。
    ///
    /// **全程不碰系统剪贴板**：`PasteboardReader` 收一个 `NSPasteboard`，
    /// 这里给它一块私有的。用 `.general` 的话，一次自检就会把用户正在复制的
    /// 东西顶掉——而这台机器上的用户可能就是正在验收的人。
    /// 外来 SVG 的分组与元素索引只读识别，保证导入不会抹掉 Figma 等工具留下的
    /// 结构语义；视觉编辑器依赖这份索引来提供后续可替换的编组导航接口。
    private static func svgStructurePreservesExternalSemantics() {
        print("SVG 结构识别（可视编辑器）")
        let source = """
        <svg xmlns="http://www.w3.org/2000/svg">
          <g id="root" data-name="根编组">
            <g id="chart" inkscape:label="趋势图"><line id="axis" x1="0" y1="0" x2="40" y2="0" stroke="#123456"/></g>
            <rect id="card" x="1" y="2" width="30" height="20" fill="#fff"/>
            <text id="title" font-size="18">标题</text>
          </g>
        </svg>
        """
        let groups = SVGStructure.groups(in: source)
        expect(groups.count == 2, "识别外部 SVG 的嵌套编组")
        expect(groups.first?.name == "根编组" && groups.last?.parentID == "root" && groups.last?.depth == 1,
               "保留编组名称、父级与层级")

        let nodes = SVGStructure.editableNodes(in: source)
        expect(nodes.map(\.tag) == ["line", "rect", "text"], "识别线条、矩形和文字的可编辑节点")
        guard let line = nodes.first else {
            expect(false, "取得线条节点")
            return
        }
        let changed = SVGStructure.updating(source, node: line, attribute: "stroke-width", value: "4.5")
        expect(changed.contains("stroke-width=\"4.5\""), "更新节点属性时仅改写对应 SVG 标签")
        expect(changed.contains("<g id=\"root\""), "改写节点属性不破坏外部编组")
    }

    private static func clipboardImport() async {
        print("粘贴通道（§4 第 2 条）")

        guard let scratch = makeScratchDataDirectory("clipboard") else {
            expect(false, "建得出临时数据目录")
            return
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard let database = try? LibraryDatabase.open(at: scratch) else {
            expect(false, "临时目录里打得出库")
            return
        }
        let store = AssetStore(database: database, root: scratch)
        let locator = SnapshotAssetLocator(root: scratch)
        let provider = FileImageProvider(locator: locator)
        let probe = MemoryImageProbe()

        guard let png = probe.pngData(CGSize(width: 48, height: 32)),
              let tiff = probe.tiffData(CGSize(width: 48, height: 32)),
              let jpeg = probe.jpegData(CGSize(width: 48, height: 32))
        else {
            expect(false, "造得出位图字节")
            return
        }
        let sourceFile = probe.writePNG(CGSize(width: 48, height: 32), to: scratch)
        let svg = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="80" viewBox="0 0 120 80">
          <rect width="120" height="80" fill="#0e7490"/>
          <circle cx="60" cy="40" r="22" fill="#facc15"/>
        </svg>
        """.utf8)

        // ---- 一、剪贴板里是什么，就分到哪一类 ----
        //
        // 这块剪贴板是私有的，跑完 `releaseGlobally` 收掉——留在系统里的话，
        // 每跑一次自检就多一块没人清的剪贴板。
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pin.selftest.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let reader = PasteboardReader(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("这是一段文字，不是图片", forType: .string)
        expect(reader.read() == .none, "剪贴板里只有文字 → 没有可粘的图片")

        // Chromium 有时不声明 `public.svg-image`，而是把同一份 SVG 源码当成
        // `public.utf8-plain-text` 放进剪贴板。这个用例正是人工复制后「没有
        // 图片素材」的最小复现，不能只测理想的 SVG UTI。
        pasteboard.clearContents()
        pasteboard.setData(svg, forType: .string)
        guard case .svg(let plainTextSVG, _) = reader.read() else {
            expect(false, "纯文本 SVG 也识别为矢量素材（Chromium 复制）")
            return
        }
        expect(plainTextSVG == svg, "纯文本通道的 SVG 源码原样保留")

        pasteboard.clearContents()
        pasteboard.setData(svg, forType: PasteboardReader.svgType)
        guard case .svg(let roundTrippedSVG, let svgName) = reader.read() else {
            expect(false, "剪贴板里的 SVG 数据 → 矢量素材那一支")
            return
        }
        expect(roundTrippedSVG == svg, "SVG 源码原样带过来（不降级成 PNG）")
        expect(svgName.hasSuffix(".svg"), "SVG 的名字带 .svg 后缀", detail: svgName)

        if let sourceFile {
            pasteboard.clearContents()
            pasteboard.writeObjects([sourceFile as NSURL])
            expect(reader.read() == .fileURLs([sourceFile]),
                   "访达复制的文件 → 文件 URL 那一支",
                   detail: "\(reader.read())")
        } else {
            expect(false, "写得出一个测试文件")
        }

        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        guard case .image(let roundTripped, let pngName, let pngSize) = reader.read() else {
            expect(false, "剪贴板里是 PNG 数据 → 位图那一支")
            return
        }
        expect(roundTripped == png, "本来就是 PNG 的位图原样带过来（不重新编码）")
        expect(pngSize == CGSize(width: 48, height: 32), "尺寸从位图数据里读出来",
               detail: "\(pngSize)")
        expect(pngName.hasSuffix(".png"), "位图的名字带 .png 后缀（决定落盘后缀）",
               detail: pngName)

        // TIFF 是剪贴板位图的通用形态（截图工具、多数浏览器都给这个）。
        // 它必须被**归一成 PNG**：`ingest` 按扩展名落盘，名字说是 png
        // 而字节是 tiff 的话，那张图在访达里双击打不开。
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        guard case .image(let normalized, _, let tiffSize) = reader.read() else {
            expect(false, "剪贴板里是 TIFF 数据 → 也算位图")
            return
        }
        expect(normalized.starts(with: [0x89, 0x50, 0x4E, 0x47]), "TIFF 被归一成了 PNG",
               detail: "头四个字节 \(Array(normalized.prefix(4)))")
        expect(tiffSize == CGSize(width: 48, height: 32), "归一之后尺寸不变",
               detail: "\(tiffSize)")

        pasteboard.clearContents()
        let jpegType = NSPasteboard.PasteboardType("public.jpeg")
        pasteboard.setData(jpeg, forType: jpegType)
        guard case .image(let normalizedJPEG, _, let jpegSize) = reader.read() else {
            expect(false, "剪贴板里是 JPEG 数据 → 位图那一支")
            return
        }
        expect(normalizedJPEG.starts(with: [0x89, 0x50, 0x4E, 0x47]), "JPEG 被归一成了 PNG")
        expect(jpegSize == CGSize(width: 48, height: 32), "JPEG 归一之后尺寸不变",
               detail: "\(jpegSize)")

        // ---- 二、临时文件：写得出、删得掉 ----
        let writer = TemporaryImageWriter(root: scratch)
        let name = PasteboardReader.suggestedName()
        guard let temporary = try? writer.write(png, named: name) else {
            expect(false, "位图写得出临时文件")
            return
        }
        expect(temporary.lastPathComponent == name, "临时文件用的是建议名",
               detail: temporary.lastPathComponent)
        expect(FileManager.default.fileExists(atPath: temporary.path), "临时文件真的落盘了")
        expect(temporary.deletingLastPathComponent().lastPathComponent != "pin-paste",
               "每个文件一个独立目录（删的时候一次清干净）",
               detail: temporary.deletingLastPathComponent().path)
        writer.cleanUp(temporary)
        expect(!FileManager.default.fileExists(atPath: temporary.deletingLastPathComponent().path),
               "清理把整个临时目录删掉")

        // 名字里的斜杠不能让写入跑到目录外面去（名字现在是我们自己造的，
        // 但这个参数是公开的，将来从剪贴板读到的名字也可能带斜杠）。
        if let escaped = try? writer.write(png, named: "a/b.png") {
            expect(escaped.deletingLastPathComponent().lastPathComponent != "b",
                   "名字里的斜杠被换掉，没有写到目录外面",
                   detail: escaped.lastPathComponent)
            writer.cleanUp(escaped)
        } else {
            expect(false, "带斜杠的名字也写得出来")
        }

        // ---- 三、粘一张位图：入库 → 摆到落点 ----
        var camera = CanvasCamera.initial
        camera.viewportSize = CGSize(width: 800, height: 600)
        let boards = BoardStore()
        boards.activeCamera = camera
        let coordinator = ImportCoordinator(
            store: store,
            prober: provider,
            boards: boards,
            locator: locator,
            tempWriter: TemporaryImageWriter(root: scratch)
        )
        let anchor = CGPoint(x: 500, y: -300)
        let payload = ClipboardPayload.image(data: png, suggestedName: name, pixelSize: CGSize(width: 48, height: 32))
        let outcomes = await coordinator.importClipboard(payload, anchor: anchor)
        expect(outcomes.count == 1, "一次粘贴一条结果", detail: "\(outcomes.count)")
        guard case .imported(let record) = outcomes.first else {
            expect(false, "粘贴位图导入成功", detail: outcomes.first?.message ?? "无结果")
            return
        }
        expect(record.origin == .paste, "来源记的是 paste", detail: "\(record.origin)")
        expect(record.originalFilename == name,
               "库里记的是「粘贴 时间.png」，不是临时路径（提示里出现临时路径等于什么都没说）",
               detail: record.originalFilename)
        expect(record.pixelSize == CGSize(width: 48, height: 32), "尺寸与位图一致")
        expect((try? await store.count()) == 1, "库里正好一条素材")

        // 落点：用户把图拖到哪儿它就出现在哪儿。粘摆在视口中心是刻意的
        // （粘贴没有"落点"），但拖入那条通道给的就是光标位置。
        let pastedElements = boards.activeScene.elements
        expect(pastedElements.count == 1, "画布上多了一个元素")
        guard let pasted = pastedElements.first else { return }
        expect(nearlyEqual(pasted.frame.midX, anchor.x) && nearlyEqual(pasted.frame.midY, anchor.y),
               "元素中心落在指定的落点上",
               detail: "\(pasted.frame) 落点 \(anchor)")
        // 定位表装好了：粘贴完立刻能解码（不然第一帧是"素材不存在"的占位）
        guard case .image(let decoded) = await provider.image(
            for: record.id, targetPixelSize: record.pixelSize
        ) else {
            expect(false, "粘贴完立刻能经真提供者解码")
            return
        }
        expect(decoded.width == 48 && decoded.height == 32, "解码出来是原尺寸")

        // 临时文件不能留在盘上：粘一百次就是一百份没人清的副本。
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: scratch.appendingPathComponent("pin-paste"), includingPropertiesForKeys: nil
        )) ?? []
        expect(leftovers.isEmpty, "导入完成后临时文件被清掉了", detail: "\(leftovers.count) 个残留")

        // ---- 三·补、名字带斜杠时，"记录里的名字"与"磁盘上的名字"必须分开 ----
        //
        // 这一段是**注入实测逼出来的**：上面那条「库里记的是「粘贴 时间.png」」
        // 用的是正常名字，而正常名字原样落盘、原样入库——把 `importClipboard`
        // 里那段"把结果文案换成用户看得懂的名字"整个删掉，它照样是绿的。
        // 一条注入打不红的断言等于没有断言，所以这里补一条**能红的**。
        //
        // 带斜杠的名字正好把两件事分开：磁盘上的文件名会被 `TemporaryImageWriter`
        // 换成 `-`（防目录穿越），而用户看到的那个（素材面板标题、提示胶囊）
        // 不该被换。两者不同，才问得出"记录里存的是哪一个"。
        let slashedName = "粘贴 19/30.png"
        let slashed = await coordinator.importClipboard(
            .image(data: png, suggestedName: slashedName, pixelSize: CGSize(width: 48, height: 32)),
            anchor: CGPoint(x: -120, y: 80)
        )
        if case .imported(let record) = slashed.first {
            expect(record.originalFilename == slashedName,
                   "名字里有斜杠时：记录的是用户看到的那个，不是磁盘上换过之后的",
                   detail: record.originalFilename)
            // 另一头钉住：临时目录的路径绝不能进库——它出现在提示里等于什么都没说，
            // 而且临时目录随时会被删掉，留着就是一条指向不存在文件的记录。
            expect(!record.originalFilename.contains(scratch.path),
                   "记录里不出现临时目录路径",
                   detail: record.originalFilename)
            expect(record.origin == .paste, "带斜杠的粘贴也记 paste")
        } else {
            expect(false, "带斜杠名字的粘贴导入成功", detail: slashed.first?.message ?? "无结果")
        }
        let leftoversAfterSecond = (try? FileManager.default.contentsOfDirectory(
            at: scratch.appendingPathComponent("pin-paste"), includingPropertiesForKeys: nil
        )) ?? []
        expect(leftoversAfterSecond.isEmpty,
               "带斜杠的那次也把临时文件清掉了", detail: "\(leftoversAfterSecond.count) 个残留")

        // ---- 三·补二、SVG：保留原件，显示时才按当前 LOD 栅格化 ----
        let svgOutcomes = await coordinator.importClipboard(
            .svg(data: svg, suggestedName: "可编辑图表.svg"),
            anchor: CGPoint(x: 180, y: 90)
        )
        guard case .imported(let svgRecord) = svgOutcomes.first else {
            expect(false, "粘贴 SVG 导入成功", detail: svgOutcomes.first?.message ?? "无结果")
            return
        }
        expect(svgRecord.originalFilename == "可编辑图表.svg", "SVG 保留可读文件名")
        expect(svgRecord.pixelSize == CGSize(width: 120, height: 80),
               "SVG 从声明中读取画布尺寸", detail: "\(svgRecord.pixelSize)")
        expect((try? Data(contentsOf: svgRecord.fileURL(in: scratch))) == svg,
               "素材库保存的是 SVG 原始字节，不是显示用的位图")
        guard case .image(let renderedSVG) = await provider.image(
            for: svgRecord.id, targetPixelSize: CGSize(width: 60, height: 40)
        ) else {
            expect(false, "SVG 入库后能在画布渲染路径解码")
            return
        }
        expect(renderedSVG.width == 60 && renderedSVG.height == 40,
               "SVG 按请求的 LOD 栅格化", detail: "\(renderedSVG.width)×\(renderedSVG.height)")

        // ---- 四、粘一批文件：走的是同一条流水线 ----
        if let sourceFile {
            let boardsB = BoardStore()
            boardsB.activeCamera = camera
            let coordinatorB = ImportCoordinator(
                store: store, prober: provider, boards: boardsB, locator: locator,
                tempWriter: TemporaryImageWriter(root: scratch)
            )
            let fileOutcomes = await coordinatorB.importClipboard(.fileURLs([sourceFile]))
            guard case .imported(let fileRecord) = fileOutcomes.first else {
                expect(false, "粘贴文件 URL 也导入成功", detail: fileOutcomes.first?.message ?? "无结果")
                return
            }
            expect(fileRecord.origin == .paste, "文件形态的来源也记 paste")
            expect(fileRecord.originalFilename == sourceFile.lastPathComponent,
                   "文件形态保留原文件名（那是真的文件名，不像位图要现造一个）",
                   detail: fileRecord.originalFilename)
            expect(boardsB.activeScene.elements.count == 1, "文件形态也摆上画布")
        }

        // ---- 五、位图也吃同一条尺寸政策（§3.9） ----
        //
        // 这条是"为什么位图要绕一个临时文件"的**证据**：位图若走一条自己的
        // `ingest(data:)`，导入上限就只在文件那条路上生效，而粘贴进来的巨图
        // 落盘之后每次全档解码都可能顶穿内存。这里把上限收到 16 点，
        // 48×32 的位图必须被拒——拒了就说明它确实过了那道闸。
        let strict = ImportCoordinator(
            store: store,
            prober: provider,
            boards: BoardStore(),
            locator: locator,
            policy: ImportPolicy(maxLongestEdge: 16, maxTotalPixels: 256),
            tempWriter: TemporaryImageWriter(root: scratch)
        )
        // 数一下拒绝前后的条数，而不是写死一个数：上面那条通道刚加过一条，
        // 写死的话这条断言会因为**别的**步骤而红，红了也看不出是谁的问题。
        let countBeforeRejection = (try? await store.count()) ?? -1
        let rejected = await strict.importClipboard(payload, anchor: nil)
        expect(rejected.first == .rejected(.tooLarge),
               "过大尺寸的位图在**复制之前**被拒（和文件那条通道同一个上限）",
               detail: rejected.first?.message ?? "无结果")
        let countAfterRejection = (try? await store.count()) ?? -1
        expect(countAfterRejection == countBeforeRejection,
               "被拒的位图没有留下半成品",
               detail: "\(countBeforeRejection) → \(countAfterRejection)")

        // ---- 六、剪贴板里没有图片：不是失败，也不产生任何东西 ----
        expect(await coordinator.importClipboard(.none).isEmpty, "没有图片时一条结果都不产生")
        expect(ImportFeedback.summary(of: []) == .nothingToPaste,
               "没有图片的摘要是 nothingToPaste（不是「0 张被拒 1 张」）")
        expect(ImportFeedback.summary(of: rejected.first.map { [$0] } ?? [])
                == .finished(imported: 0, rejected: 1, firstFailure: ImportPolicy.tooLargeMessage),
               "被拒的摘要把原因带出来")
    }

    // MARK: - 拖入通道（§4 第 1 条）

    /// 拖入画布：`Coordinator.drop` 这一层。
    ///
    /// ## 为什么只钉到这一层
    ///
    /// `draggingEntered` / `performDragOperation` 要一个真的拖放会话，
    /// 而 `NSDraggingInfo` 是 AppKit 在拖放进行中才造出来的，没有可用的假件。
    /// 能钉的是**它下游那一步**——而这一步恰好是最容易"看起来正常、结果全错"
    /// 的地方：忘了把视图点换算成世界点的话，拖放本身照样成功（源应用还会
    /// 播放"已放入"动画），图却摆到视口外面去了。
    private static func dropInChannel() {
        print("拖入通道（§4 第 1 条）")

        let fixture = makeElementFixture(count: 1)
        let (coordinator, _) = makeCoordinator(scene: fixture.scene)

        var received: [ClipboardPayload] = []
        var receivedPoints: [CGPoint] = []
        var verdict = true
        coordinator.onDrop = { payload, point in
            received.append(payload)
            receivedPoints.append(point)
            return verdict
        }

        // 一、空的载荷不接。两种空都要挡住：什么都没有、以及"一批空文件"。
        // 返回 true 会让源应用播放"已放入"动画，而画布上什么都没出现——
        // 那比明确拒收更让人困惑。
        var emptyFiles = [URL]()
        expect(coordinator.drop(.none, atViewPoint: CGPoint(x: 10, y: 10)) == false,
               "空载荷不接（不给源应用一个假的成功）")
        expect(coordinator.drop(.fileURLs(emptyFiles), atViewPoint: CGPoint(x: 10, y: 10)) == false,
               "一批空文件也不接")
        emptyFiles.append(URL(fileURLWithPath: "/tmp/x.png"))
        expect(ClipboardPayload.fileURLs(emptyFiles).isEmpty == false, "非空的一批不算空")

        // 二、视图点要换算成**世界点**再交出去。
        let urls = [
            URL(fileURLWithPath: "/tmp/pin-drop-a.png"),
            URL(fileURLWithPath: "/tmp/pin-drop-b.png"),
        ]
        let viewPoint = CGPoint(x: 640, y: 180)
        let expected = CanvasCamera.initial.viewToWorld(viewPoint)
        expect(coordinator.drop(.fileURLs(urls), atViewPoint: viewPoint), "非空批次接下了")
        let firstPoint = receivedPoints.first
        expect(firstPoint.map { nearlyEqual($0.x, expected.x) && nearlyEqual($0.y, expected.y) } ?? false,
               "交给导入的是世界坐标（不是原样的视图坐标）",
               detail: "收到 \(firstPoint.map(String.init(describing:)) ?? "无")，期望 \(expected)")

        // 三、顺序原样带过去：网格摆位按"第几张"排格子，换了顺序图就换个位置。
        expect(received.first == .fileURLs(urls), "URL 顺序原样带过去",
               detail: "\(urls.map(\.lastPathComponent))")

        // 四、闭包的判断要能传出去。它是"收不收"，`performDragOperation` 直接返回它。
        verdict = false
        expect(coordinator.drop(.fileURLs(urls), atViewPoint: viewPoint) == false,
               "拒绝要传得出去（导入层说不收，宿主就不能说收下了）")
        verdict = true

        // 五、换算用的是**当前**相机，不是建的时候那一份。相机是会被平移和缩放的，
        // 存一份副本的实现到这里就露馅——表现是"拖进去的图落在很早以前的位置"。
        var panned = CanvasCamera.initial
        panned.center = CGPoint(x: panned.center.x + 200, y: panned.center.y - 120)
        coordinator.applyExternalCamera(panned)
        _ = coordinator.drop(.fileURLs(urls), atViewPoint: viewPoint)
        let expectedAfterPan = panned.viewToWorld(viewPoint)
        let lastPoint = receivedPoints.last
        expect(lastPoint.map { nearlyEqual($0.x, expectedAfterPan.x) && nearlyEqual($0.y, expectedAfterPan.y) } ?? false,
               "平移之后换算跟着相机走（不是建的时候那一份相机）",
               detail: "收到 \(lastPoint.map(String.init(describing:)) ?? "无")，期望 \(expectedAfterPan)")

        // 六、**网页里拖出来的位图**也走同一条路。它没有原文件，落盘前要编码，
        // 所以载荷形态和文件完全不同——但落点换算、收不收的判断必须一模一样。
        // 少了这条，一个"只处理文件 URL"的实现照样能过前面全部断言。
        let pixelSize = CGSize(width: 24, height: 17)
        guard let blank = makeBlankImage(pixelSize),
              let png = NSBitmapImageRep(cgImage: blank).representation(using: .png, properties: [:])
        else {
            expect(false, "造得出一张 PNG 位图夹具")
            return
        }
        // 相机显式归零：上一条断言刚把它平移过，不归零的话这里量的是"平移之后
        // 的换算"——那件事上一条已经钉过了，混在一起会让失败原因读不出来。
        coordinator.applyExternalCamera(.initial)
        let imagePoint = CGPoint(x: 300, y: 420)
        let expectedImagePoint = CanvasCamera.initial.viewToWorld(imagePoint)
        expect(coordinator.drop(
            .image(data: png, suggestedName: "粘贴 x.png", pixelSize: pixelSize),
            atViewPoint: imagePoint
        ), "位图载荷接下了（网页里拖出来的图没有原文件）")
        if case .image = received.last {
            let point = receivedPoints.last
            expect(point.map {
                nearlyEqual($0.x, expectedImagePoint.x) && nearlyEqual($0.y, expectedImagePoint.y)
            } ?? false,
                   "位图的落点也换算成世界坐标",
                   detail: "收到 \(point.map(String.init(describing:)) ?? "无")，期望 \(expectedImagePoint)")
        } else {
            expect(false, "位图原样传到导入层", detail: "\(String(describing: received.last))")
        }

        // 七、⌘V 转发出去。画布不自己读剪贴板——读了就绕开了"三条通道同一个入口"。
        var pasteCount = 0
        coordinator.onPaste = { pasteCount += 1 }
        coordinator.paste()
        expect(pasteCount == 1, "⌘V 转发到粘贴处理（画布不自己读剪贴板）")
    }

    /// 画布收得下的拖拽类型，必须覆盖**网页实际宣告的那一套**。
    ///
    /// ## 这份清单是实测来的，不是想出来的
    ///
    /// Spike Phase 2 里把花瓣首页的图拖出来，把 `draggingPasteboard.types`
    /// 原样打了出来。要点是：**没有 `public.file-url`**——网页给的是一份
    /// promised file（`com.apple.pasteboard.promised-file-url`），图片本体是
    /// `public.tiff` / `public.png`。第一版画布只登记 `.fileURL`，于是网页拖拽
    /// 连 `draggingEntered` 都不会被调用，界面上一点反应都没有。
    ///
    /// 断言钉在**交集**上而不是逐条相等：多登记几个类型没有害处，少一个
    /// 才会让通道静默消失。
    private static func canvasAcceptsWebImageDrags() {
        print("画布收得下网页拖出的图")

        // 实测原样（Spike 报告 §8.2 第 1 行，共 29 项，这里保留与图片有关的）。
        let webDragTypes: [NSPasteboard.PasteboardType] = [
            NSPasteboard.PasteboardType("org.webmproject.webp"),
            NSPasteboard.PasteboardType("com.apple.WebKit.custom-pasteboard-data"),
            .tiff,
            .png,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"),
            NSPasteboard.PasteboardType("NSPromiseContentsPboardType"),
            .URL,
            .string,
        ]
        let accepted = CanvasHostNSView.acceptedDragTypes
        let matched = Set(webDragTypes).intersection(accepted)
        expect(!matched.isEmpty,
               "网页图拖拽的类型里有画布登记过的（否则 draggingEntered 根本不会被调用）",
               detail: "交集 \(matched.map(\.rawValue).sorted())")

        // Finder 那条路不能因为这次改动被挤掉。
        expect(accepted.contains(.fileURL), "仍然收 Finder 拖来的文件")
        expect(accepted == PasteboardReader.acceptedDragTypes,
               "画布登记的类型与读取器支持的类型完全一致")
    }

    /// 画布右键菜单里有「粘贴图片」，且它的可用状态跟着剪贴板走。
    private static func canvasContextMenuOffersPaste() {
        print("画布右键菜单")

        let fixture = makeElementFixture(count: 1)
        let (_, view) = makeCoordinator(scene: fixture.scene)

        let menu = view.menu(for: NSEvent())
        let titles = menu?.items.map(\.title) ?? []
        expect(titles.contains("粘贴图片"), "右键菜单里有「粘贴图片」", detail: "\(titles)")

        guard let item = menu?.items.first(where: { $0.title == "粘贴图片" }) else { return }
        expect(item.action == #selector(CanvasHostNSView.paste(_:)),
               "菜单项接的是标准的 paste: 选择器（和 ⌘V 同一条路）",
               detail: String(describing: item.action))

        // 可用状态必须**当场问**，不能写死成 true：剪贴板里没图时菜单项要是可点的，
        // 用户点下去只会得到一句"剪贴板里没有图片"——菜单本来就该在这时变灰。
        let pasteboard = NSPasteboard.general
        let types = pasteboard.availableType(from: [.png, .tiff])
        let hasURL = pasteboard.canReadObject(forClasses: [NSURL.self])
        expect(view.validateMenuItem(item) == (hasURL || types != nil),
               "菜单项的灰与不灰跟着真实剪贴板走",
               detail: "剪贴板可用类型 \(String(describing: types))，有 URL \(hasURL)")
    }

    // MARK: - 素材面板接真（§3.4）

    /// 截图来源的真实现（§3.4）：条目来自素材库（新的在前）、缩略图走共享管线、
    /// 库的迟到接线、模型侧的面板跟随。
    private static func screenshotMaterialProvider() async {
        print("素材面板接真（§3.4）")

        guard let scratch = makeScratchDataDirectory("material-provider") else {
            expect(false, "建得出临时数据目录")
            return
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard let database = try? LibraryDatabase.open(at: scratch) else {
            expect(false, "临时目录里打得出库")
            return
        }
        let store = AssetStore(database: database, root: scratch)
        let locator = SnapshotAssetLocator(root: scratch)
        let probe = MemoryImageProbe()
        let shared = FileImageProvider(locator: locator)
        let environment = AppEnvironment(profile: .cc, dataDirectory: scratch)

        // ---- 启动状态：还没拉过 ----

        let lookup = AssetStoreLookup()
        let provider = ScreenshotMaterialProvider(
            environment: environment, assets: lookup, images: shared
        )
        expect(provider.content == .idle, "启动即 idle（还没拉过，不是空）")

        // ---- 库的迟到接线：没开 → 说得出口的失败；开好 → 真内容 ----

        await provider.refresh()
        expect(provider.content == .failed("素材库还没准备好"),
               "库没开 → 「素材库还没准备好」，不是空列表",
               detail: "实际 \(provider.content)")

        lookup.store = store
        await provider.refresh()
        expect(provider.content == .loaded([]),
               "库开好之后：空库 → 空列表（不是失败）",
               detail: "实际 \(provider.content)")

        // ---- 内容映射与排序（§3.4 口径：added_at DESC，新的在前）----
        // 入库顺序故意与时间顺序相反：按"先入库先显示"排的话这里正好倒过来。

        // 素材画 64×64：缩略图目标是 32×32，走的是**缩小**路径——档位阶梯
        // 不会把图放大到超过原尺寸（小图请求大目标时给的是原尺寸），
        // 所以这里要用比目标大的素材才能断言"解到目标尺寸"。
        var titlesByIngest: [String] = []
        let dated: [(seconds: TimeInterval, size: CGSize)] = [
            (1_700_000_200, CGSize(width: 64, height: 64)),
            (1_700_000_100, CGSize(width: 64, height: 64)),
            (1_700_000_300, CGSize(width: 64, height: 64)),
        ]
        for entry in dated {
            guard let url = probe.writePNG(entry.size, to: scratch),
                  let record = try? await store.ingest(
                      from: url, using: shared,
                      now: Date(timeIntervalSince1970: entry.seconds)
                  ) else {
                expect(false, "入库三份不同时间的素材")
                return
            }
            // 定位表立刻装好：面板缩略图与画布解码走同一份定位数据。
            locator.insert(record)
            titlesByIngest.append(url.lastPathComponent)
        }
        // 期望顺序按时间倒排：300 → 200 → 100（入库顺序是 200, 100, 300）。
        let titlesByTime = [titlesByIngest[2], titlesByIngest[0], titlesByIngest[1]]

        // 刷新中间态：先落 loading。数据库读在后台执行器上，必定让出一拍，
        // 所以 `Task.yield()` 之后看到的就该是 loading 而不是终态。
        let refreshTask = Task { @MainActor in await provider.refresh() }
        await Task.yield()
        expect(provider.content == .loading, "刷新先落 loading，再落结果")
        await refreshTask.value

        guard case .loaded(let items) = provider.content else {
            expect(false, "三份素材都在库里 → 列表已加载", detail: "实际 \(provider.content)")
            return
        }
        expect(items.count == 3, "列表条目数等于库内素材数", detail: "\(items.count) 条")
        expect(items.map(\.title) == titlesByTime,
               "新的在前（added_at DESC，与入库顺序无关）",
               detail: "实际 \(items.map(\.title))")
        let records = (try? await store.allAssets()) ?? []
        guard let newestRecord = records.first, let firstItem = items.first else {
            expect(false, "库与列表都有内容")
            return
        }
        expect(firstItem.id == MaterialItemID(newestRecord.id.raw),
               "条目身份 = 素材身份（MaterialItemID 取 AssetID）")
        expect(firstItem.title == newestRecord.originalFilename, "标题是原文件名")
        expect(firstItem.thumbnail == newestRecord.id, "缩略图引用素材 ID")
        expect(firstItem.kind == .image, "截图条目是图片形态")

        // ---- 刷新后条目身份稳定 ----
        // 身份每次刷新都换新的话，SwiftUI 会把列表当成全新内容整个重排，
        // 看起来像"素材在乱跳"。

        await provider.refresh()
        guard case .loaded(let again) = provider.content else {
            expect(false, "二次刷新仍加载")
            return
        }
        expect(again.map(\.id) == items.map(\.id), "刷新后条目身份稳定（同素材同条目）")

        // ---- 读库失败 → .failed（失败必须说得出口） ----
        // 关掉连接池之后下一次读取必然抛错——这是库里数据之外的第二条失败路径，
        // 面板的失败分支不是只有"库没开"一种走法。

        try? database.pool.close()
        await provider.refresh()
        guard case .failed(let readFailure) = provider.content else {
            expect(false, "读库失败 → .failed，不是停在 loading",
                   detail: "实际 \(provider.content)")
            return
        }
        expect(readFailure.hasPrefix("读不了素材库："),
               "失败文案带上「读不了素材库」",
               detail: readFailure)

        // ---- 缩略图走共享管线 ----

        expect(
            await ScreenshotMaterialProvider(environment: environment, assets: lookup)
                .thumbnail(for: firstItem, targetPixelSize: CGSize(width: 32, height: 32)) == nil,
            "没接图片管线 → 缩略图请求返回 nil（行视图退图标占位）"
        )

        guard let thumbnailResult = await provider.thumbnail(
            for: firstItem, targetPixelSize: CGSize(width: 32, height: 32)
        ) else {
            expect(false, "接了图片管线的提供者不返回 nil")
            return
        }
        switch thumbnailResult {
        case .image(let image):
            expect(image.width == 32 && image.height == 32,
                   "缩略图解到目标尺寸",
                   detail: "实际 \(image.width)×\(image.height)")
        case .cancelled:
            expect(false, "缩略图请求未被取消")
        case .missing:
            expect(false, "文件在库，不落 missing")
        case .failed(let reason):
            expect(false, "缩略图解得出", detail: reason)
        }

        // 缩略图与画布同一份缓存：同档直接取不再解码（decodeCount 不涨）。
        // 面板自己另建解码体系的话，这里会是两次解码。
        let decodesBefore = shared.decodeCount
        if case .image = await shared.image(
            for: firstItem.thumbnail!, targetPixelSize: CGSize(width: 32, height: 32)
        ) {
            expect(shared.decodeCount == decodesBefore,
                   "缩略图与画布共用缓存（同档命中不解码）")
        } else {
            expect(false, "共享管线同档重取仍拿到图")
        }

        // ---- 闸门接在缩略图路径上（§3.4：接的是**线**，不是闸门自己的逻辑） ----
        // 十个并发缩略图请求经真提供者打进来：同时只有 4 个在解。
        // 替身每个请求占住 30ms——闸门没接在路径上的话十发一起冲，峰值是 10。

        let probeImages = ConcurrencyProbeImages()
        let gatedProvider = ScreenshotMaterialProvider(
            environment: environment, assets: lookup, images: probeImages
        )
        let burst = (0..<10).map { _ in
            Task { @MainActor in
                await gatedProvider.thumbnail(
                    for: firstItem, targetPixelSize: CGSize(width: 32, height: 32)
                )
            }
        }
        for task in burst { _ = await task.value }
        expect(probeImages.peak <= 4, "并发缩略图被闸门压在 4 个以内",
               detail: "峰值 \(probeImages.peak)")

        // ---- 并发闸门 ----

        await thumbnailGateUnit()

        // ---- 模型侧：面板跟着库走 ----

        guard let modelScratch = makeScratchDataDirectory("material-model") else {
            expect(false, "建得出模型场景的临时目录")
            return
        }
        defer { try? FileManager.default.removeItem(at: modelScratch) }
        let modelEnvironment = AppEnvironment(profile: .cc, dataDirectory: modelScratch)

        // 库还没开时刷面板：截图源报「没准备好」——失败分支与空状态分支必须
        // 分得开（浮层命中测试走的正是这个状态：失败视图也得接住点击）。
        let unprepared = WorkspaceModel(environment: modelEnvironment)
        await unprepared.refreshMaterialSources()
        expect(
            unprepared.source(MaterialSourceCatalog.screenshots)?.provider.content
                == .failed("素材库还没准备好"),
            "库没开：模型刷面板得到「素材库还没准备好」",
            detail: "实际 \(String(describing: unprepared.source(MaterialSourceCatalog.screenshots)?.provider.content))"
        )

        // 真实启动顺序：prepareStorage → restore → importFiles。
        let model = WorkspaceModel(environment: modelEnvironment)
        model.prepareStorage()
        expect(model.storageError == nil, "模型场景里库开得出")
        await model.restore()
        expect(model.source(MaterialSourceCatalog.screenshots)?.provider.content == .loaded([]),
               "恢复后面板是空列表（库开好且没素材）",
               detail: "实际 \(String(describing: model.source(MaterialSourceCatalog.screenshots)?.provider.content))")

        guard let modelFile = probe.writePNG(CGSize(width: 64, height: 64), to: modelScratch) else {
            expect(false, "写得出模型场景的素材")
            return
        }
        let outcomes = await model.importFiles([modelFile])
        expect(outcomes[modelFile]?.isImported == true, "模型导入成功")
        guard let screenshots = model.source(MaterialSourceCatalog.screenshots),
              case .loaded(let panelItems) = screenshots.provider.content else {
            expect(false, "导入后面板是已加载",
                   detail: "实际 \(String(describing: model.source(MaterialSourceCatalog.screenshots)?.provider.content))")
            return
        }
        expect(panelItems.contains { $0.title == modelFile.lastPathComponent },
               "导入后面板立刻出现新条目（不用重启、不用手动刷新）")
        expect(model.storageError == nil, "导入全程没有写库失败")

        // 面板条目经模型里的提供者拿得到真像素（端到端）。
        guard let panelItem = panelItems.first,
              let panelThumbnail = await screenshots.provider.thumbnail(
                  for: panelItem, targetPixelSize: CGSize(width: 32, height: 32)
              ) else {
            expect(false, "模型里的面板条目取得到缩略图结果")
            return
        }
        switch panelThumbnail {
        case .image(let image):
            expect(image.width == 32 && image.height == 32, "模型里的面板条目解得出缩略图")
        case .cancelled:
            expect(false, "模型侧缩略图未被取消")
        case .missing:
            expect(false, "模型侧文件在库，不落 missing")
        case .failed(let reason):
            expect(false, "模型侧缩略图解得出", detail: reason)
        }
    }

    // MARK: - 恢复：素材文件丢了（§3.5）

    /// §3.5 的第二条：素材文件被人在访达里删掉时，元素仍在、走 `.missing`
    /// 分支显示占位与提示——**不静默删元素**（静默删等于替用户做了决定）。
    ///
    /// §3.2 已经钉过"文件不在 → 解码 .missing"，这里补的是**恢复链路**：
    /// 真导入 → 访达删文件 → 重开库 → 元素还在、还引用那条素材、解码落
    /// `.missing`。占位与提示的界面行为在第一批的失败重试组里已经钉过。
    private static func restoreKeepsMissingFileElements() async {
        print("恢复：素材文件丢了（§3.5）")

        guard let scratch = makeScratchDataDirectory("restore-missing") else {
            expect(false, "建得出临时数据目录")
            return
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard let database = try? LibraryDatabase.open(at: scratch) else {
            expect(false, "临时目录里打得出库")
            return
        }
        let store = AssetStore(database: database, root: scratch)
        let locator = SnapshotAssetLocator(root: scratch)
        let provider = FileImageProvider(locator: locator)
        let probe = MemoryImageProbe()
        let writer = SceneWriteScheduler(store: SceneStore(database: database))
        let boards = BoardStore()
        boards.library = writer
        // 真实启动顺序（§3.3 的教训）：board 行先于元素行。
        writer.persist(board: boards.activeBoard, sort: 0)

        guard let url = probe.writePNG(CGSize(width: 48, height: 32), to: scratch) else {
            expect(false, "写得出素材")
            return
        }
        let coordinator = ImportCoordinator(
            store: store, prober: provider, boards: boards, locator: locator
        )
        guard case .imported(let record) = await coordinator.importFiles([url])[url] else {
            expect(false, "导入成功")
            return
        }
        await writer.flush()
        expect(boards.activeScene.elements.count == 1, "导入后画布上一个元素")

        // 用户在访达里把文件删掉。库行还在——访达删的是文件，不是库。
        let fileURL = store.root.appendingPathComponent(record.relativePath)
        try? FileManager.default.removeItem(at: fileURL)
        expect(!FileManager.default.fileExists(atPath: fileURL.path), "文件确实不在了（测试前提）")

        // 重开 + 恢复：元素仍在，不静默删。
        guard let reopened = try? LibraryDatabase.open(at: scratch) else {
            expect(false, "同一个目录重开打得出库")
            return
        }
        guard let snapshot = try? await LibrarySnapshot.load(from: reopened) else {
            expect(false, "重开读得出快照")
            return
        }
        expect(snapshot.elementCount == 1, "文件丢了，元素还在库里")
        let revived = BoardStore(snapshot: snapshot)
        expect(revived.activeScene.elements.count == 1, "恢复后元素仍在画布上")
        guard let element = revived.activeScene.elements.first else { return }
        expect(element.kind == .image(asset: record.id), "元素还引用那条素材（不是换成占位元素）")

        // 恢复后的解码走 `.missing`——渲染器拿它显示占位与提示
        //（第一批的失败重试组钉过界面行为，这里钉恢复链路）。
        let revivedProvider = FileImageProvider(
            locator: SnapshotAssetLocator(root: scratch, assets: snapshot.assets)
        )
        switch await revivedProvider.image(for: record.id, targetPixelSize: record.pixelSize) {
        case .missing:
            expect(true, "解码丢文件的素材 → .missing（占位与提示的入口）")
        case .image:
            expect(false, "文件不在 → 不落 .image")
        case .failed(let reason):
            expect(false, "文件不在 → 不落 .failed（那是「读不了」，不是「不在」）", detail: reason)
        case .cancelled:
            expect(false, "文件不在 → 不落 .cancelled")
        }
    }

    /// 导入结果摘要（§3.6）：`ImportFeedback.summary` 是界面读到的唯一口径，
    /// 计数与「第一条失败」的取舍都在这里钉死。纯值映射，不碰库。
    ///
    /// 第一版按字典迭代序取「第一条失败」，两条断言随运行随机红——Swift
    /// Dictionary 不保证迭代顺序（哈希种子按进程随机）。所以签名带 `orderedBy`：
    /// 第一条失败按用户选文件的先后取，与哈希布局无关。
    private static func importFeedbackSummary() async {
        print("导入结果摘要（§3.6）")

        func imported(_ n: Int) -> AssetRecord {
            AssetRecord(
                id: AssetID(),
                originalFilename: "样例-\(n).png",
                relativePath: "assets/ab/样例-\(n).png",
                byteCount: 100 + n,
                contentHash: "dummy-\(n)",
                pixelSize: CGSize(width: 40, height: 40),
                exifOrientation: 1,
                kind: .image,
                origin: .fileImport,
                addedAt: Date()
            )
        }
        func key(_ n: Int) -> URL {
            URL(fileURLWithPath: "/tmp/样例-\(n).png")
        }
        let order = (0...4).map { key($0) }

        // ---- 混合批：计数分开，失败文案取用户顺序里的第一条 ----
        // 字典按哈希序迭（实测这批键是 2,1,0,3,4）：按字典序取的话
        // 第一条失败是 1 号还是 3 号取决于进程哈希种子——这正是要避开的。
        let mixed: [URL: ImportCoordinator.FileOutcome] = [
            key(0): .imported(imported(0)),
            key(1): .rejected(.failed("读不了这个文件")),
            key(2): .imported(imported(2)),
            key(3): .rejected(.tooLarge),
            key(4): .rejected(.failed("第二个失败原因")),
        ]
        guard case .finished(let importedCount, let rejectedCount, let firstFailure) =
            ImportFeedback.summary(of: mixed, orderedBy: order)
        else {
            expect(false, "摘要一定是 .finished")
            return
        }
        expect(importedCount == 2 && rejectedCount == 3, "混合批：2 张成功、3 张被拒")
        expect(firstFailure == "读不了这个文件", "失败文案取用户顺序里的第一条（1 号文件）")

        // ---- 全成功：没有失败行 ----

        let allGood: [URL: ImportCoordinator.FileOutcome] = [
            key(0): .imported(imported(0)),
            key(1): .imported(imported(1)),
        ]
        expect(
            ImportFeedback.summary(of: allGood, orderedBy: [key(0), key(1)])
                == .finished(imported: 2, rejected: 0, firstFailure: nil),
            "全成功 → 2 张、0 被拒、无失败文案"
        )

        // ---- 全失败：数字与文案都出得来（超限的文案走 FileRejection 自己的口径） ----

        let allBad: [URL: ImportCoordinator.FileOutcome] = [
            key(0): .rejected(.tooLarge),
            key(1): .rejected(.failed("不是图片")),
        ]
        expect(
            ImportFeedback.summary(of: allBad, orderedBy: [key(0), key(1)])
                == .finished(imported: 0, rejected: 2, firstFailure: ImportPolicy.tooLargeMessage),
            "全失败 → 0 张、2 被拒、第一条失败是超限文案"
        )

        // ---- 空批 ----

        expect(
            ImportFeedback.summary(of: [:], orderedBy: [])
                == .finished(imported: 0, rejected: 0, firstFailure: nil),
            "空批 → 全部为零，界面不会显示任何内容"
        )

        // ---- 调用方给的列表与结果字典对不齐：兜底把没点到的也数进去 ----

        let misaligned: [URL: ImportCoordinator.FileOutcome] = [
            key(0): .rejected(.failed("A")),
            key(9): .rejected(.failed("B")),
        ]
        expect(
            ImportFeedback.summary(of: misaligned, orderedBy: [key(0)])
                == .finished(imported: 0, rejected: 2, firstFailure: "A"),
            "列表之外的条目也计数：2 张被拒，第一条失败仍是列表里的"
        )
    }

    /// 调试入口（§3.7）：`--import` 的参数解析与 `--library-report` 的报告正文。
    /// 解析与报告都是纯函数，直接断言；报告再走一次真库（临时目录）对照，
    /// 钉「真库的 journal 是 WAL」这类只能实测的段落。
    private static func debugEntries() async {
        print("调试入口（§3.7）")

        // ---- `--import` 参数解析 ----

        let parsedA = HeadlessImport.parse(arguments: ["pin", "--import", "a.png", "b.png"])
        expect(
            parsedA.paths == ["a.png", "b.png"] && parsedA.dataDirectory == nil,
            "路径段收到下一个 -- 开头参数为止；无 --data-dir 时目录为 nil"
        )
        let parsedB = HeadlessImport.parse(
            arguments: ["pin", "--import", "a.png", "--data-dir", "/tmp/x", "b.png"]
        )
        expect(
            parsedB.paths == ["a.png", "b.png"] && parsedB.dataDirectory?.path == "/tmp/x",
            "--data-dir 在路径段里也认：不被当成路径，前后两段路径都收到"
        )
        let parsedC = HeadlessImport.parse(
            arguments: ["pin", "--import", "a.png", "--library-report"]
        )
        expect(parsedC.paths == ["a.png"], "下一个 -- 开头的参数截断路径段")
        let parsedD = HeadlessImport.parse(
            arguments: ["pin", "--import", "--data-dir", "/tmp/x", "a.png"]
        )
        expect(
            parsedD.paths == ["a.png"] && parsedD.dataDirectory?.path == "/tmp/x",
            "--data-dir 放在路径段最前也认"
        )
        let parsedE = HeadlessImport.parse(arguments: ["pin", "--library-report"])
        expect(parsedE.paths.isEmpty && parsedE.dataDirectory == nil, "没有 --import 时是空解析")

        // ---- 报告正文（纯函数） ----

        func sampleAsset(_ name: String) -> AssetRecord {
            AssetRecord(
                id: AssetID(),
                originalFilename: name,
                relativePath: "assets/ab/\(name)",
                byteCount: 1234,
                contentHash: "dummy",
                pixelSize: CGSize(width: 40, height: 30),
                exifOrientation: 1,
                kind: .image,
                origin: .fileImport,
                addedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
        let structure = LibraryStructure(
            version: 1,
            tables: ["asset", "board"],
            indexes: ["idx_element_asset"],
            columns: ["asset": ["id", "relative_path"], "board": ["id"]]
        )
        let report = LibraryReport.render(
            directory: URL(fileURLWithPath: "/tmp/示例库"),
            structure: structure,
            journalMode: "wal",
            fileSizes: (main: 4096, wal: 512, shm: 32768),
            assets: [sampleAsset("样例.png")],
            boardCount: 1,
            elementCount: 2
        )
        expect(report.contains("数据目录：/tmp/示例库"), "报告含数据目录")
        expect(report.contains("版本：user_version = 1"), "报告含版本行")
        expect(report.contains("表（2 张）：asset, board"), "报告含表清单")
        expect(report.contains("索引（1 个）：idx_element_asset"), "报告含索引清单")
        expect(report.contains("asset（2 列）：id, relative_path"), "报告含列清单")
        expect(report.contains("journal 模式：wal"), "报告含 journal 模式")
        expect(
            report.contains("pin.sqlite：4096 字节")
                && report.contains("pin.sqlite-wal：512 字节")
                && report.contains("pin.sqlite-shm：32768 字节"),
            "报告含主文件与 -wal/-shm 三个大小（漏一个就是少报磁盘占用）"
        )
        expect(report.contains("画布：1 块") && report.contains("元素：2 个"), "报告含画布与元素计数")
        expect(report.contains("素材：1 条"), "报告含素材计数")
        expect(report.contains("样例.png"), "素材清单带原文件名")
        expect(report.contains("40×30"), "素材清单带像素尺寸")
        expect(report.contains("1234 字节"), "素材清单带字节数")
        expect(report.contains("2023-11-14 22:13:20"), "素材清单带固定格式的添加时间")

        // ---- 报告走一遍真库（临时目录） ----

        guard let scratch = makeScratchDataDirectory("library-report") else {
            expect(false, "建得出临时数据目录")
            return
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard let database = try? LibraryDatabase.open(at: scratch) else {
            expect(false, "临时目录里打得出库")
            return
        }
        let store = AssetStore(database: database, root: scratch)
        let probe = MemoryImageProbe()
        var realAssets: [AssetRecord] = []
        for _ in 0..<2 {
            guard let png = probe.writePNG(CGSize(width: 48, height: 32), to: scratch),
                  let record = try? await store.ingest(from: png, origin: .fileImport, using: probe)
            else { continue }
            realAssets.append(record)
        }
        expect(realAssets.count == 2, "真库入两条素材（测试前提）")
        do {
            let structure = try await database.structure()
            let journal = try await database.journalMode()
            let sizes = database.fileSizes()
            let sceneStore = SceneStore(database: database)
            let realReport = LibraryReport.render(
                directory: scratch,
                structure: structure,
                journalMode: journal,
                fileSizes: sizes,
                assets: try await store.allAssets(),
                boardCount: try await sceneStore.boardCount(),
                elementCount: try await sceneStore.elementCount()
            )
            expect(realReport.contains("journal 模式：wal"), "真库的 journal 是 WAL（实测，不按记忆）")
            expect(realReport.contains("版本：user_version = 1"), "真库版本进报告")
            expect(realReport.contains("素材：2 条"), "真库素材计数进报告")
            expect(realReport.contains("表（"), "真库结构清单进报告")
        } catch {
            expect(false, "真库报告读得出来", detail: "\(error)")
        }
    }

    /// 缩略图闸门的并发与取消行为（§3.4：只给可见行发请求之外的第二道限制）。
    private static func thumbnailGateUnit() async {
        print("缩略图并发闸门（§3.4）")
        let gate = ThumbnailGate(limit: 2)

        let a = await gate.acquire()
        let b = await gate.acquire()
        expect(a && b, "limit 2：前两个请求立刻拿到位子")

        // 第三个排队：位子没空出来之前拿不到。
        // 闸门与这个测试都在主 actor 上，`Task.yield()` 之后排队者必定已经
        // 挂进队列（单线程 actor：它先跑到自己的挂起点，这边才继续）。
        var thirdResult: Bool?
        let third = Task { @MainActor in thirdResult = await gate.acquire() }
        await Task.yield()
        expect(thirdResult == nil, "第三个排队中：位子还没空出来")
        gate.release()
        _ = await third.value
        expect(thirdResult == true, "空出一个位子后，排队者拿到")

        // 还掉一个位子之后，下一个请求立刻拿到；再占满，第五个排队。
        gate.release()
        let fourth = await gate.acquire()
        expect(fourth, "还掉一个位子后，下一个请求立刻拿到")

        var fifthResult: Bool?
        let fifth = Task { @MainActor in fifthResult = await gate.acquire() }
        await Task.yield()
        expect(fifthResult == nil, "占满后第五个排队中")
        // 排队中被取消 → false：没拿到过位子，不解码、也不还位子。
        fifth.cancel()
        _ = await fifth.value
        expect(fifthResult == false, "排队中被取消 → false（没拿到位子，不解码）")

        // 被取消的等待者不占位子：两位都还掉之后立刻有位子。
        // 摘除没生效的话，这里会少一个位子或者挂在队列里的幽灵被二次唤醒。
        gate.release()
        gate.release()
        let free = await gate.acquire()
        expect(free, "被取消的等待者不占位子：两位都还掉后立刻有位子")
    }

    private static func makeScratchDataDirectory(_ label: String) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pin-selftest-\(label)-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return nil
        }
    }

    /// SHA-256（十六进制小写），与 `AssetStore.copyAndHash` 同口径。
    ///
    /// 自检自己算一遍，拿去和库里记的对：**库里那个值不能信它自己**——
    /// "哈希写进库了"和"哈希是对的"是两件事。
    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 写一张**带 EXIF 方向**的 JPEG——真文件、真元数据（§3.2 的"实测"靠它）。
    ///
    /// 存储尺寸是 w×h，方向写进 EXIF（5–8 时摆正之后是 h×w）。方向这一位是
    /// ImageIO 真写进文件的，不是测试自己在旁边记的数——被测代码读到的 6
    /// 因此是有来头的，断言才不是在复述测试自己写下的值。
    private static func writeOrientedJPEG(
        width: Int,
        height: Int,
        orientation: Int,
        to directory: URL
    ) -> URL? {
        guard let image = makeBlankImage(CGSize(width: width, height: height)) else { return nil }
        let url = directory.appendingPathComponent("oriented-\(orientation)-\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImagePropertyOrientation: orientation] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }

    /// 写一张**带透明通道**的 PNG：四周透明，正中一块实色。
    ///
    /// 刻意做成**上下左右都对称**：读像素要经过一次位图重画，而位图的行序与
    /// Core Graphics 的 y 轴朝向相反——对称图形让"坐标系翻转"这件事无法把
    /// 断言弄假：角落就是角落，正中的还是正中。
    private static func writeTransparentPNG(size: CGSize, to directory: URL) -> URL? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 8, height > 8,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        guard let image = context.makeImage() else { return nil }

        let url = directory.appendingPathComponent("transparent-\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }

    /// 读一张 `CGImage` 里某一点的 RGBA（8 位）。
    ///
    /// 把图**原样画进一块自己的位图**再取那一个像素：读的是真实像素，不是
    /// 属性里的声明。"有 alpha 通道"和"这个点是透明的"是两件事——透明通道
    /// 有没有被解码路径压平，只有后者钉得住。
    private static func pixelRGBA(
        of image: CGImage, at point: CGPoint
    ) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let x = Int(point.x)
        let y = Int(point.y)
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let offset = (y * width + x) * 4
        return (buffer[offset], buffer[offset + 1], buffer[offset + 2], buffer[offset + 3])
    }

    /// `ImageFileProbing` 的测试实现：一个**只用内存**的图片来源。
    ///
    /// 持久化断言需要一个能读磁盘 PNG 的探针，但自检不碰真实素材
    /// （路线图 §6）——于是素材由它现造：`writePNG` 把一张空白位图写成
    /// 临时文件，`probe` 对文件实际解码、报出真实属性。
    @MainActor
    private final class MemoryImageProbe: ImageFileProbing {
        /// 每次成功探测的文件与结论。断言用它确认"探针读的是库里那一份"。
        private(set) var probed: [(URL, ImageFileFacts)] = []

        func probe(_ url: URL) async -> ImageFileFacts? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any]
            else { return nil }
            let facts = ImageFileFacts(
                pixelSize: CGSize(
                    width: (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0,
                    height: (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
                ),
                exifOrientation: (properties[kCGImagePropertyOrientation] as? Int) ?? 1
            )
            probed.append((url, facts))
            return facts
        }

        /// 一张 `size` 的 PNG 字节。写不出来返回 `nil`。
        ///
        /// 剪贴板那条通道要的是**字节**而不是文件：位图在剪贴板上本来就没有
        /// 文件。有了它，自检才能造出一份"真的能被 ImageIO 读懂的位图数据"，
        /// 而不是拿一段随便的 Data 去骗过类型检查。
        func pngData(_ size: CGSize) -> Data? {
            guard let image = makeBlankImage(size) else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }

        /// 一张 `size` 的 TIFF 字节。剪贴板位图的通用形态，用来验"不是 PNG
        /// 的位图会被归一成 PNG"。
        func tiffData(_ size: CGSize) -> Data? {
            guard let image = makeBlankImage(size) else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .tiff, properties: [:])
        }

        func jpegData(_ size: CGSize) -> Data? {
            guard let image = makeBlankImage(size) else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:])
        }

        /// 在 `directory` 里写一张 `size` 的 PNG，返回文件位置。写不出来返回 `nil`。
        func writePNG(_ size: CGSize, to directory: URL) -> URL? {
            guard let data = pngData(size) else { return nil }
            let url = directory.appendingPathComponent("\(UUID().uuidString).png")
            do {
                try data.write(to: url)
                return url
            } catch {
                return nil
            }
        }
    }

    /// 只观察"同时有几个请求在跑"的图片管线替身（§3.4 的闸门接线断言）。
    ///
    /// 每个请求占住一小段时间，只数并发、不解码。并发数记在 `peak` 上：
    /// 真闸门（limit 4）会把十发请求压成每轮 4 个；闸门没接在路径上的话
    /// 十发一起冲进来，峰值就是 10。
    @MainActor
    private final class ConcurrencyProbeImages: ImageProvider {
        let residency = ImageResidency()
        private var active = 0
        private(set) var peak = 0
        private let hold: UInt64

        init(holdNanoseconds: UInt64 = 30_000_000) { self.hold = holdNanoseconds }

        func metadata(for asset: AssetID) async -> ImageMetadata? { nil }
        func cachedImage(for asset: AssetID, atMost tier: LODTier) -> CachedImage? { nil }
        func releaseOffscreenPixels(of asset: AssetID) {}

        func image(for asset: AssetID, targetPixelSize: CGSize) async -> ImageRequestResult {
            active += 1
            peak = max(peak, active)
            // 取消也要还计数：`try?` 吞掉 CancellationError，往下照样减。
            try? await Task.sleep(nanoseconds: hold)
            active -= 1
            return .failed("并发探针替身不解码")
        }
    }

    // MARK: - 性能埋点

    /// 性能探针**默认关着**。
    ///
    /// 这条断言放在整个自检的**最后**，因为它读的是"跑完前面所有断言之后探针里
    /// 有什么"。上面几百条断言把渲染、缩放、缓存、取消、持久化的路径全走了一遍——
    /// 如果探针是开着的，这些路径上的 `measure` / `count` 会把它填满。
    ///
    /// ## 为什么这件事值得一条断言
    ///
    /// 「关着的时候零开销」是 `PerformanceProbe` 在注释里做的承诺，而**承诺没有
    /// 断言就是没有承诺**：把 `isEnabled` 的默认值改成 `true`、或者在某个构造点
    /// 忘了关，症状是"产品跑起来顺手多记了几十万个样本"——不报错、不变慢到能察觉、
    /// 报告里也看不出来（报告本来就开着探针）。只有这里会红。
    ///
    /// 它能证明的是**不记账**，不是"零开销"：关着的时候每个埋点仍有**一次布尔
    /// 判断**。要证明零开销得看汇编，那不是自检该做的事。
    private static func performanceProbeIsOffByDefault() {
        print("性能埋点")
        expect(!PerformanceProbe.isEnabled,
               "默认关着（只有 `--perf-report` 那份报告会打开）")
        expect(PerformanceProbe.durations.isEmpty,
               "跑完整个自检，探针一个耗时样本都没记",
               detail: "记了 \(PerformanceProbe.durations.count) 段")
        expect(PerformanceProbe.counters.isEmpty,
               "跑完整个自检，探针一个计数都没记",
               detail: "记了 \(PerformanceProbe.counters.values.reduce(0, +)) 次")
    }

    // MARK: - 画布不越界

    /// 画布内容不许画到自己的边界以外。
    ///
    /// 这条是**用户实测发现**的：四列合成素材在 100% 缩放下比视口宽，最左一列
    /// 压到了左侧素材面板上，看起来像"面板没渲染"。成因是 `CALayer` 默认不裁剪
    /// 子层，而画布是 `HStack` 里靠右的兄弟视图——超出视口的元素照常被合成。
    ///
    /// 断言只能钉住"裁剪开着"这一件事，钉不住视觉效果；真正的视觉证据是
    /// `--snapshot` 里那张 100% 缩放的内容截图（它渲染的是整个工作台，
    /// 越界的话素材会盖在面板上，肉眼一看就知道）。
    private static func canvasDoesNotDrawOutsideItsBounds() {
        print("画布不越界")
        let (coordinator, view) = makeCoordinator(scene: CanvasScene())

        guard let hostLayer = view.layer else {
            expect(false, "画布视图有 backing layer")
            return
        }
        expect(hostLayer.masksToBounds,
               "画布图层裁剪到自己的边界（否则内容会画到左侧面板上）")

        // 裁的必须是**视口这一层**：`worldLayer` 带着相机变换，给它加蒙版
        // 等于在世界坐标里裁，会把"元素有一部分在视口外"变成"整个元素不画"。
        // 所以这里反过来验：世界层不许被裁。
        expect(coordinator.worldLayerMasksToBounds == false,
               "世界层不裁（裁它会让跨越视口边界的元素整块消失）")
    }

    // MARK: - 浮层与画布的层级

    /// 画布是基底、浮层在它上面——这两条都是**结构**，不是画出来的样子，
    /// 所以只能用视图树和命中测试来钉。
    ///
    /// ## 为什么必须测，不能靠读代码
    ///
    /// 画布是 AppKit 的 `NSView`，浮层是 SwiftUI 画在它上面的内容。AppKit 的命中
    /// 测试先看子视图，**画布是真实子视图而浮层不是**——浮层完全可能被整个吞掉。
    /// 表现是"按钮点了没反应，画布反而平移了一下"，而截图上看不出任何异常
    /// （浮层照常画在最上面）。这正是这次结构调整最大的风险点。
    ///
    /// 实测结论：**不会吞**。SwiftUI 的宿主视图在命中测试里会先问自己画的内容，
    /// 只有落空时才落到 representable 的 NSView 上。但这是"实测如此"，
    /// 不是"显然如此"——所以留一条断言在这里，将来 SwiftUI 改了行为会红。
    ///
    /// ## 哪种注入能让它红（这一步差点得出反的结论）
    ///
    /// 按"先问它能不能红"的规矩，我拿两种注入试过，第一次探到的**是假死角**：
    ///
    /// - **重写 `CanvasHostNSView.hitTest` 一律返回自己**——六条断言全绿。
    ///   看着像断言没牙，其实是注入没走到：宿主视图先答自己画的内容，那个点
    ///   根本轮不到画布那一层，重写它等于写了段死代码。**"注入不红"有两种解读：
    ///   断言瞎了，或者注入根本没被调用。**不把这两种分开就下结论，会冤枉自己的断言。
    /// - **把浮层挂到 `.background`（= 压到画布后面）**——「素材面板拿得到点击」
    ///   立刻红（命中到 `CanvasHostNSView`）。这才是这条失败模式真实的走法：
    ///   **层级挂反**，不是画布伸手去抢。
    ///
    /// 结论：命中类的断言要注在**层级**上，别注在被命中的那一方身上。
    private static func floatingLayerSitsAboveCanvas() {
        print("浮层在画布之上")

        let model = WorkspaceModel(environment: .resolve())
        let size = CGSize(width: 1280, height: 800)
        let hosting = NSHostingView(rootView: WorkspaceView(model: model))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        // SwiftUI 的首轮布局有一部分是异步的（和 `--snapshot` 同一个理由）。
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        hosting.layoutSubtreeIfNeeded()

        guard let canvas = firstCanvasView(in: hosting) else {
            expect(false, "视图树里找得到画布视图")
            return
        }

        // 一、画布铺满来源栏右侧的全部区域。
        //
        // 第一版是 `HStack{来源栏, 面板, 画布}`，画布宽度 = 窗口 - 栏 - 面板。
        // 改成"画布是基底"之后它等于窗口减去来源栏——这条断言就是那次结构调整本身：
        // 把面板放回 HStack，画布立刻窄掉一个面板宽，这里会红。
        let canvasFrame = canvas.convert(canvas.bounds, to: nil)
        let expectedWidth = size.width - DesignTokens.Metrics.sourceRailWidth
        expect(abs(canvasFrame.width - expectedWidth) < 0.5,
               "画布铺满来源栏右侧（没有被面板挤窄）",
               detail: "画布宽 \(canvasFrame.width)，期望 \(expectedWidth)")
        expect(abs(canvasFrame.minX - DesignTokens.Metrics.sourceRailWidth) < 0.5,
               "画布从来源栏右边缘开始",
               detail: "起点 x = \(canvasFrame.minX)")

        // 二、面板那块地方**是画布的地盘**，但命中到的是浮层。
        //
        // 这两条合起来才说明"浮在画布上"：前者证明画布在面板底下铺着（不是被挤开），
        // 后者证明浮层没被画布吞掉。
        let panelCenter = CGPoint(
            x: DesignTokens.Metrics.sourceRailWidth
                + DesignTokens.Metrics.floatingPanelInset
                + DesignTokens.Metrics.panelWidth / 2,
            y: size.height / 2
        )
        expect(canvasFrame.contains(panelCenter),
               "面板底下是画布（画布没有被面板挤开）",
               detail: "面板中点 \(panelCenter)，画布 \(canvasFrame)")
        expect(hitTest(hosting, at: panelCenter) !== canvas,
               "素材面板拿得到点击，没被画布吞掉",
               detail: describeHit(hitTest(hosting, at: panelCenter)))

        // 三、画布空白处仍然命中画布本身——浮层没有反过来盖住整块画布。
        // 少了这条，一个"整块画布都被浮层挡住"的实现也能通过上面两条。
        let emptyCanvasPoint = CGPoint(x: size.width - 80, y: size.height - 200)
        expect(hitTest(hosting, at: emptyCanvasPoint) === canvas,
               "画布空白处仍然命中画布",
               detail: describeHit(hitTest(hosting, at: emptyCanvasPoint)))

        // 四、底部这一行有多少宽度是可点的浮层。
        //
        // 工具条的位置由布局算出来（它在"画布减去浮层"之后剩下的空间里居中），
        // 断言不重算那套算式——重算等于把同一个可能写错的东西写两遍。
        // 改成一扫：沿底部那一行按点取样，数有多少个点落在浮层上。
        // 工具条约 200pt 宽，阈值取 120 留足余量。
        let bottomY = DesignTokens.Metrics.toolbarBottomInset
            + DesignTokens.Metrics.toolbarHeight / 2
        var clickableWidth: CGFloat = 0
        var x = DesignTokens.Metrics.sourceRailWidth
        while x < size.width {
            if hitTest(hosting, at: CGPoint(x: x, y: bottomY)) !== canvas { clickableWidth += 2 }
            x += 2
        }

        expect(clickableWidth > 120,
               "底部工具条拿得到点击（扫一行看有多少宽度落在浮层上）",
               detail: "可点宽度 \(clickableWidth)pt")

        // 五、工具条要落在**看得见的画布**正中。
        //
        // 这条是量出来的教训：第一版把提示挂在工具条右边，`HStack` 于是让工具条在
        // "扣掉提示之后剩下的空间"里居中——实测 1280 宽时工具条中心 688pt、画布
        // 中心 812pt，偏了 124pt，肉眼能看出来。当时注释里写的是"居中在看得见的
        // 画布上"，也就是说**注释比代码更早地宣布了它想要的结果**。
        //
        // 这条同时钉住了窄窗口的退让：窗口 960 时两份提示放不下，`ViewThatFits`
        // 该丢掉提示只留工具条。退让没生效的话那一行会溢出，工具条被顶到 680pt 去，
        // 这里就会红。（提示自己不参与命中测试，所以命中段里只有工具条。）
        let floatingOccupied = DesignTokens.Metrics.floatingPanelInset * 2
            + DesignTokens.Metrics.panelWidth
        for width in [CGFloat(1280), 960] {
            let runs = bottomRowHitRuns(width: width, height: 800, model: model)
            let expectedCenter = (DesignTokens.Metrics.sourceRailWidth + floatingOccupied + width) / 2
            guard let extent = toolbarExtent(
                in: runs, minX: DesignTokens.Metrics.sourceRailWidth + floatingOccupied
            ) else {
                expect(false, "宽 \(Int(width))：底部找得到工具条",
                       detail: "命中段 \(runs)")
                continue
            }
            let center = (extent.0 + extent.1) / 2
            expect(abs(center - expectedCenter) < 8,
                   "宽 \(Int(width))：工具条居中在看得见的画布上",
                   detail: "工具条 \(extent.0)..\(extent.1) 中点 \(center)，画布中点 \(expectedCenter)")
        }
    }

    /// 在指定窗口尺寸下搭一个真实窗口，扫出底部那一行里**落点不在画布上**的横向区段。
    ///
    /// 这些区段就是浮层（工具条）真正占到的玻璃宽度——也是"浮层有没有被画布吞掉"
    /// 唯一的直接证据。提示是 `allowsHitTesting(false)`，不会出现在这里。
    private static func bottomRowHitRuns(
        width: CGFloat, height: CGFloat, model: WorkspaceModel
    ) -> [(CGFloat, CGFloat)] {
        let size = CGSize(width: width, height: height)
        let hosting = NSHostingView(rootView: WorkspaceView(model: model))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        // 和 `--snapshot` 同一个理由：SwiftUI 首轮布局有一部分是异步的。
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        hosting.layoutSubtreeIfNeeded()

        guard let canvas = firstCanvasView(in: hosting) else { return [] }
        let y = DesignTokens.Metrics.toolbarBottomInset + DesignTokens.Metrics.toolbarHeight / 2
        var runs: [(CGFloat, CGFloat)] = []
        var start: CGFloat?
        var x = DesignTokens.Metrics.sourceRailWidth
        while x < size.width {
            if hitTest(hosting, at: CGPoint(x: x, y: y)) !== canvas {
                if start == nil { start = x }
            } else if let s0 = start {
                runs.append((s0, x))
                start = nil
            }
            x += 2
        }
        if let s0 = start { runs.append((s0, size.width)) }
        return runs
    }

    /// 工具条实际占到的横向范围：命中段里落在**看得见的画布区**里的那一簇。
    ///
    /// 三处细节都不能省：
    ///
    /// - **先滤掉画布区左边的段**。面板与工具条在同一扫描线上：面板底部和
    ///   工具条都贴着窗口底边。§3.4 起面板整块可命中（`MaterialPanel` 的
    ///   `contentShape`——点面板空白处不许穿透到画布），于是这条扫描线上
    ///   多出 70..330 的面板段。工具条只活在"画布减去浮层"剩下的区域里，
    ///   按 `minX` 一滤就分开了。
    /// - **滤掉窄段**。面板的调宽把手（8pt 宽）也落在这条扫描线上，它不是
    ///   工具条的一部分；工具条的按钮是 26pt。第一版没滤，取到的"工具条"
    ///   是 322..330 那个把手，断言报出「工具条中点 326」这种一眼假的数。
    /// - **整簇取首尾**，不能只取第一段：按钮之间有留白，段与段是分开的。
    ///   间隔小于 20pt 的算同一条工具条。
    private static func toolbarExtent(
        in runs: [(CGFloat, CGFloat)], minX: CGFloat
    ) -> (CGFloat, CGFloat)? {
        let buttons = runs.filter { $0.0 >= minX && $0.1 - $0.0 >= 20 }
        guard let first = buttons.first else { return nil }
        var maxX = first.1
        for run in buttons.dropFirst() where run.0 - maxX < 20 { maxX = run.1 }
        return (first.0, maxX)
    }

    /// 在视图树里找画布视图。命中测试返回的就是它，所以要按类型找。
    // MARK: - 花瓣来源的内嵌网页

    /// 花瓣面板的内容是一张**内嵌网页**，而网页和画布一样是 AppKit 的 `NSView`。
    ///
    /// ## 为什么上一节的结论不能直接搬过来
    ///
    /// `floatingLayerSitsAboveCanvas` 证明的是「SwiftUI 浮层不会被画布吞掉」，
    /// 依据是"SwiftUI 宿主视图在命中测试里会先问自己画的内容"。网页这条不适用：
    /// **两个原生视图之间是标准的 AppKit 命中测试**，谁在后谁先被问。画布完全
    /// 可能把网页盖住，表现是「网页点不动，反而把画布拖走了」——而截图上看不出
    /// 任何异常（网页照常画在最上面）。
    ///
    /// ## 顺带钉住"换个来源再切回来，网页还是那一张"
    ///
    /// 网页归 `WorkspaceModel` 所有，不归视图。视图被拆掉（切来源、折叠面板）
    /// 时网页必须还活着——不然用户刚登录完，切一下来源回来就要重新加载。
    private static func browserPanelIsWired() {
        print("花瓣面板的内嵌网页")

        let model = WorkspaceModel(environment: .resolve())
        model.activeSourceID = MaterialSourceCatalog.huaban
        let browser = model.webBrowser

        let size = CGSize(width: 1280, height: 800)
        let hosting = NSHostingView(rootView: WorkspaceView(model: model))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        guard let canvas = firstCanvasView(in: hosting) else {
            expect(false, "视图树里找得到画布视图")
            return
        }
        guard let web = firstWebView(in: hosting) else {
            expect(false, "花瓣来源下视图树里找得到网页视图")
            return
        }
        expect(web === browser.webView,
               "树里那张网页就是模型持有的那一张（不是另建一张）")

        // 面板内容区的中点。导航条 40 + 标题 34 之后才是网页，所以取样点压在
        // 半高处——上半部分可能落在导航条上。
        let panelCenter = CGPoint(
            x: DesignTokens.Metrics.sourceRailWidth
                + DesignTokens.Metrics.floatingPanelInset
                + DesignTokens.Metrics.panelWidth / 2,
            y: size.height / 2
        )
        let hit = hitTest(hosting, at: panelCenter)
        expect(isInside(hit, web),
               "网页拿得到点击，没被画布吞掉",
               detail: describeHit(hit))
        expect(!isInside(hit, canvas),
               "面板那一块不是画布在接点击",
               detail: describeHit(hit))

        // 画布空白处仍然命中画布——网页没有反过来盖住整块画布。
        let emptyCanvasPoint = CGPoint(x: size.width - 80, y: size.height - 200)
        expect(hitTest(hosting, at: emptyCanvasPoint) === canvas,
               "画布空白处仍然命中画布",
               detail: describeHit(hitTest(hosting, at: emptyCanvasPoint)))

        // 切走来源：网页离开视图树，但**同一个实例还在模型手里**。
        model.activeSourceID = MaterialSourceCatalog.screenshots
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()

        expect(firstWebView(in: hosting) == nil,
               "切走来源后网页离开视图树",
               detail: firstWebView(in: hosting).map { "\(type(of: $0))" } ?? "nil")
        expect(model.webBrowser === browser,
               "切走来源不销毁网页（换回来还要是同一张）")

        // 折叠：和"切走来源"走的是同一条拆装路径，但**这一条才是用户要的**——
        // 折叠是采集时的常规动作（腾出画布位置），而花瓣登录一次很贵。
        // 展开之后必须是**同一张**网页，否则就是重新加载、重新登录。
        model.activeSourceID = MaterialSourceCatalog.huaban
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        expect(firstWebView(in: hosting) === web, "切回花瓣后还是同一张网页")

        model.isMaterialPanelVisible = false
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        expect(firstWebView(in: hosting) == nil, "折叠后网页离开视图树",
               detail: firstWebView(in: hosting).map { "\(type(of: $0))" } ?? "nil")
        expect(model.webBrowser === browser, "折叠不销毁网页")

        model.isMaterialPanelVisible = true
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        expect(firstWebView(in: hosting) === web,
               "展开后还是同一张网页（没重新造一张，所以不会重新加载/重新登录）")
    }

    /// 折叠之后，面板原来的位置要留下一个能点回来的按钮，而且**不能被画布吞掉**。
    ///
    /// 存在理由和浮层那组同源：按钮是 SwiftUI 画的，而它下面是画布那个 `NSView`。
    /// 点不中的表现是"折叠之后再也找不到面板了"——而工具条上那个开关还在，
    /// 所以用户未必会报告，只会觉得"这个折叠功能坏了"。
    private static func collapsedPanelLeavesAButton() {
        print("折叠后的方形按钮")

        let model = WorkspaceModel(environment: .resolve())
        model.activeSourceID = MaterialSourceCatalog.huaban

        let size = CGSize(width: 1280, height: 800)
        let hosting = NSHostingView(rootView: WorkspaceView(model: model))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        guard let canvas = firstCanvasView(in: hosting) else {
            expect(false, "视图树里找得到画布视图")
            return
        }

        // 展开时：那块地方是面板，不该有什么"方形按钮"的断言——先确认这是个
        // 真开关，而不是恒真。
        // 落点从**产品代码用的同一组常量**算，不是在这里重算一遍：
        // 折叠前后要重合，重算一遍就等于把同一个可能写错的东西写两遍。
        let buttonCenter = CGPoint(
            x: DesignTokens.Metrics.sourceRailWidth
                + DesignTokens.Metrics.panelToggleLeading
                + DesignTokens.Metrics.panelToggleSize / 2,
            y: size.height - DesignTokens.Metrics.panelToggleTop
                - DesignTokens.Metrics.panelToggleSize / 2
        )
        // 先自证取样点没跑偏：展开时那一点该落在面板上（面板浮在画布上）。
        // 没有这一条的话，取样点算错（比如落进左侧来源栏）也会让下面那条"通过"。
        expect(hitTest(hosting, at: buttonCenter) !== canvas,
               "展开时那一点落在面板上（取样点在画布区里，没跑到来源栏去）",
               detail: describeHit(hitTest(hosting, at: buttonCenter)))

        model.isMaterialPanelVisible = false
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        hosting.layoutSubtreeIfNeeded()

        // 这一条是有牙的：按钮若不在那儿，那一点**什么都没有**，AppKit 的命中
        // 测试就落到画布那个 NSView 上，这里当场变红。（注入验证过。）
        let whileCollapsed = hitTest(hosting, at: buttonCenter)
        expect(whileCollapsed !== canvas,
               "折叠后左边缘顶部那一点不是画布在接点击（按钮浮在画布之上）",
               detail: describeHit(whileCollapsed))

        // 画布其余地方仍然可点。
        let farCanvasPoint = CGPoint(x: size.width - 80, y: size.height - 200)
        expect(hitTest(hosting, at: farCanvasPoint) === canvas,
               "折叠后画布空白处仍然命中画布",
               detail: describeHit(hitTest(hosting, at: farCanvasPoint)))
    }

    /// 工具条在空间不够时**从右往左**逐个收起，最少剩最左边一个。
    ///
    /// ## 为什么要钉"单调"和"前缀"两件事
    ///
    /// 上一版是 `ViewThatFits` 的整条丢/不丢：阈值两侧来回翻，看起来在抽搐。
    /// 换成逐格退让之后，这两条性质就是"不再抽搐"的**形式化说法**：
    ///
    /// - **单调**：宽度变小，显示的条目数**不会变多**。变多就会来回翻。
    /// - **前缀**：留下的永远是全集的前缀——收的一定是右边那些。
    ///   做不到的话，"最少剩左侧第一个"这句话就没有依据。
    private static func toolbarCollapsesFromTheRight() {
        print("工具条逐格退让")

        let chrome = PanelChrome.default.toolbar
        let all = ToolbarSlot.allCases

        expect(ToolbarSlot.visible(availableWidth: 4000, chrome: chrome) == all,
               "够宽时全部显示")
        expect(ToolbarSlot.visible(availableWidth: 0, chrome: chrome) == all,
               "宽度还没量出来时先全给（别让工具条先闪一下空的）")

        let narrow = ToolbarSlot.visible(availableWidth: 260, chrome: chrome)
        expect(narrow.count < all.count, "挤到 260 点时会收起几条",
               detail: "留了 \(narrow.count) / \(all.count)")
        expect(narrow.first == .selectTool, "最少也要留最左边那一个")

        // 单调 + 前缀：扫一遍宽度。
        var previousCount = all.count
        for width in stride(from: CGFloat(1600), through: 40, by: -20) {
            let slots = ToolbarSlot.visible(availableWidth: width, chrome: chrome)
            expect(slots.count <= previousCount,
                   "宽度 \(Int(width))：变窄不会让条目变多（否则就是来回翻）",
                   detail: "\(previousCount) → \(slots.count)")
            previousCount = min(previousCount, slots.count)
            expect(Array(all.prefix(slots.count)) == slots,
                   "宽度 \(Int(width))：留下的永远是前缀（收的是右边那些）",
                   detail: "\(slots.map(\.self))")
            expect(slots.last?.isDivider != true,
                   "宽度 \(Int(width))：末尾不会留一条悬空的分隔线")
        }

        // 极窄：不能一条都不剩——工具条整个消失，用户就没有切工具/导入的入口了。
        for width in [CGFloat(0), 1, 40, 120] {
            let slots = ToolbarSlot.visible(availableWidth: width, chrome: chrome)
            expect(slots.count >= max(1, chrome.minimumVisibleSlots),
                   "宽度 \(Int(width))：至少留 \(chrome.minimumVisibleSlots) 个",
                   detail: "留了 \(slots.count)")
        }
    }

    /// 面板能拖多宽：静态上限认得窗口大小，且永远给画布留得下一条。
    ///
    /// 拉宽面板是这次的功能，而**拉过头会把画布拉没**——那时用户下一步
    /// （把图从网页拖到画布上）就没有落点了，而这个后果只有拖到底才发现。
    private static func panelWidthPolicyKeepsCanvasVisible() {
        print("面板宽度上限")

        let rail = DesignTokens.Metrics.sourceRailWidth
        let inset = DesignTokens.Metrics.floatingPanelInset

        for windowWidth in [CGFloat(1280), 960, 1440, 2560] {
            let canvasArea = windowWidth - rail
            let maxWidth = PanelWidthPolicy.maximum(canvasAreaWidth: canvasArea)
            let remaining = canvasArea - inset * 2 - maxWidth
            expect(remaining >= DesignTokens.Metrics.minVisibleCanvasWidth,
                   "窗口 \(Int(windowWidth))：拖到最宽仍留得下画布",
                   detail: "面板上限 \(maxWidth)，剩下 \(remaining)")
            expect(maxWidth <= DesignTokens.Metrics.panelMaxWidth,
                   "窗口 \(Int(windowWidth))：不超过静态上限",
                   detail: "\(maxWidth)")
        }

        // 沉浸式浏览要的是真能拉宽——420 那个老上限放网页太窄。
        let wide = PanelWidthPolicy.maximum(canvasAreaWidth: 1280 - rail)
        expect(wide > 420, "默认窗口下面板能拖得比老上限宽（网页需要）",
               detail: "上限 \(wide)")

        // 极窄窗口：算出来的可能是负的，而 `200...负数` 是崩，不是钳制。
        for narrow in [CGFloat(0), 100, 300, 500] {
            let maxWidth = PanelWidthPolicy.maximum(canvasAreaWidth: narrow)
            expect(maxWidth >= DesignTokens.Metrics.panelMinWidth,
                   "画布区 \(Int(narrow))：上限不小于最小宽度（否则区间非法会崩）",
                   detail: "\(maxWidth)")
        }
        expect(PanelWidthPolicy.maximum(canvasAreaWidth: 0)
                == DesignTokens.Metrics.panelMaxWidth,
               "宽度还没量出来时退回静态上限")
    }

    /// 地址栏只放行 http / https。
    ///
    /// 这条是**纯函数**断言，因为它是安全边界而不是手感：地址栏是用户能把任意
    /// 字符串送进 `WKWebView.load` 的唯一入口，`file://` 和 `javascript:` 在这条
    /// 入口上没有任何正当用途。
    private static func addressBarAcceptsOnlyWebURLs() {
        print("地址栏的 URL 校验")

        for raw in ["huaban.com", "https://huaban.com/", "http://example.com/a?b=1"] {
            expect(WebBrowserModel.normalized(raw) != nil, "接受 \(raw)")
        }
        expect(WebBrowserModel.normalized("huaban.com")?.scheme == "https",
               "没写 scheme 时补成 https")
        for raw in ["", "   ", "file:///etc/passwd", "javascript:alert(1)",
                    "ftp://example.com/x", "about:blank"] {
            expect(WebBrowserModel.normalized(raw) == nil, "拒绝 \(raw)",
                   detail: WebBrowserModel.normalized(raw)?.absoluteString ?? "nil")
        }
    }

    private static func firstWebView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for subview in view.subviews {
            if let found = firstWebView(in: subview) { return found }
        }
        return nil
    }

    /// `view` 是不是 `ancestor` 自己或它的后代。网页的命中结果可能是 WKWebView
    /// 内部的子视图，直接比 `===` 会漏掉。
    private static func isInside(_ view: NSView?, _ ancestor: NSView) -> Bool {
        var node = view
        while let current = node {
            if current === ancestor { return true }
            node = current.superview
        }
        return false
    }

    private static func firstCanvasView(in view: NSView) -> CanvasHostNSView? {
        if let canvas = view as? CanvasHostNSView { return canvas }
        for subview in view.subviews {
            if let found = firstCanvasView(in: subview) { return found }
        }
        return nil
    }

    /// 命中测试。
    ///
    /// **`hitTest` 要的是父视图坐标系里的点**，不是视图自己那套。`NSHostingView`
    /// 的 `isFlipped` 是 `true`，但它的父视图（窗口的 frame view）不是——照着
    /// `isFlipped` 去翻 y 会**正好扫到窗口的另一头**。第一版就是这么写的，
    /// 结果是"底部工具条一个字都点不到"，而工具条在截图里明明画着。
    ///
    /// 所以这里的点一律按 **AppKit 窗口坐标（原点在左下）** 给。
    private static func hitTest(_ hosting: NSView, at point: CGPoint) -> NSView? {
        hosting.hitTest(NSPoint(x: point.x, y: point.y))
    }

    private static func describeHit(_ view: NSView?) -> String {
        view.map { "\(type(of: $0))" } ?? "nil"
    }

    // MARK: - 选择与直接操控（C2）
    //
    // ## 这一组为什么先有几何断言，再有端到端断言
    //
    // 手柄与缩放错位的表现是"手柄看得见但点不中""拖某个角图片会翻面"——
    // 都要靠手感和肉眼去发现，而且发现得晚。所以 `selectionGeometryIsExact()`
    // 先在纯函数上把四个角的映射、锚点、等比、下限逐条钉死；后面的端到端断言
    // 才只需要验"这条路上确实用了它"。
    //
    // ## 探针读的是什么
    //
    // 覆盖层相关的断言**不读 `coordinator.overlay`**（那是输入，不是结果），
    // 读的是 `rendered*` 那几个从真实 `CAShapeLayer.path` 反读出来的数——
    // "通道通了但没人画"和"画了"必须能区分开。

    /// 合成一个指针输入。视图点由相机算，省得每处再换算一遍（算错一次查半天）。
    private static func pointerInput(
        world: CGPoint,
        camera: CanvasCamera,
        modifiers: CanvasModifiers = [],
        button: CanvasPointerButton = .left,
        clickCount: Int = 1
    ) -> CanvasPointerInput {
        CanvasPointerInput(
            viewPoint: camera.worldToView(world),
            worldPoint: world,
            modifiers: modifiers,
            clickCount: clickCount,
            button: button,
            timestamp: 0
        )
    }

    private static func keyInput(
        _ keyCode: UInt16,
        characters: String = "",
        modifiers: CanvasModifiers = [],
        isARepeat: Bool = false
    ) -> CanvasKeyInput {
        CanvasKeyInput(
            characters: characters,
            keyCode: keyCode,
            modifiers: modifiers,
            isARepeat: isARepeat
        )
    }

    /// 带**真实窗口**的协调器。
    ///
    /// 撤销那组必须用它：撤销栈不是画布自己的，是窗口的 `UndoManager`
    /// （`CanvasContext.undoManager` 的实现就是 `view?.window?.undoManager`）。
    /// 拿一个没进窗口的视图去测撤销，测到的是"没有撤销"，而不是"撤销对不对"。
    private static func makeWindowedCoordinator(
        scene: CanvasScene,
        selection: Set<CanvasElementID> = []
    ) -> (CanvasHostView.Coordinator, CanvasHostNSView, NSWindow) {
        let (coordinator, view) = makeCoordinator(scene: scene, selection: selection)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(view)
        // 撤销管理器由窗口惰性提供（`NSWindow.undoManager` 是只读属性），
        // 所以这里只能"把视图放进窗口"，塞不进一个自己的——这也是对的：
        // 产品路径拿的就是窗口那一个，测试用别的话测的就不是同一条路。
        //
        // **`isReleasedWhenClosed` 必须关掉。** 它的默认值是 `true`，
        // 于是 `close()` 会把窗口多释放一次：Swift 这边还持有一个引用，
        // AppKit 那边已经把它丢进自动释放池——崩溃发生在**几百行之后**
        // 某个不相干的自动释放池弹出时，栈里完全看不出是谁干的。
        // 实测就是它：撤销那组跑完之后，最后的缓动断言炸在 `objc_release` 里。
        window.isReleasedWhenClosed = false
        // 关掉"按事件自动分组"。
        //
        // 产品里它是**开着**的（默认），而且正合适：一次拖动只在 `pointerUp`
        // 登记一次，而每次鼠标事件之间主运行循环都会转一圈，所以一次操作
        // 恰好落进一个分组。自检里没有运行循环可转——从头到尾都在同一个
        // 事件里——于是几十条登记会全部挤进同一个分组，`undo()` 一把全撤。
        // 那测的就不是"一次操作一条记录"了。
        window.undoManager?.groupsByEvent = false
        return (coordinator, view, window)
    }

    private static func selectionGeometryIsExact() {
        print("选择几何（手柄、缩放）")

        // 世界 (0,0,80,60) 在 800×600、中心在原点、1× 的相机下落在视图正中。
        let camera = CanvasCamera.initial
        let frame = CGRect(x: 0, y: 0, width: 80, height: 60)
        let view = camera.worldToView(frame)
        let centers = SelectionGeometry.handleCenters(of: frame, camera: camera)

        // 一、四个角手柄落在正确的角上。
        //
        // 这条看着显然，但它是**唯一**能把"左上"和"左下"搞反的断言：反了之后
        // 手柄照样画得出来、照样点得中，只是拖左上角时动的是左下角——
        // 手感上表现为"有时候拖不动"，没有断言就只能靠运气发现。
        expect(centers[.topLeft] == CGPoint(x: view.minX, y: view.minY),
               "左上角手柄在左上", detail: "\(String(describing: centers[.topLeft]))")
        expect(centers[.topRight] == CGPoint(x: view.maxX, y: view.minY), "右上角手柄在右上")
        expect(centers[.bottomLeft] == CGPoint(x: view.minX, y: view.maxY), "左下角手柄在左下")
        expect(centers[.bottomRight] == CGPoint(x: view.maxX, y: view.maxY), "右下角手柄在右下")

        // 二、命中区 = 边长 + 两侧外扩。画 9pt、抓 19pt。
        expect(SelectionGeometry.handle(at: centers[.topLeft]!, of: frame, camera: camera) == .topLeft,
               "正中手柄点得中")
        let slopEdge = CGPoint(x: view.minX + SelectionGeometry.handleSize / 2 + 3, y: view.minY)
        expect(SelectionGeometry.handle(at: slopEdge, of: frame, camera: camera) == .topLeft,
               "手柄外侧的余量也算命中（画 9pt、抓 19pt）")
        let outside = CGPoint(
            x: view.minX - SelectionGeometry.handleSize / 2 - SelectionGeometry.handleHitSlop - 2,
            y: view.minY
        )
        expect(SelectionGeometry.handle(at: outside, of: frame, camera: camera) == nil,
               "余量之外不再是手柄（否则手柄会吃掉一大片点击）")

        // 三、等比缩放：锚点是对角，比例不变。
        let grew = SelectionGeometry.resized(
            frame, handle: .bottomRight, to: CGPoint(x: 160, y: 60), proportional: true
        )
        expect(grew.origin == CGPoint(x: 0, y: 0), "拖右下角时左上角不动",
               detail: "origin=\(grew.origin)")
        expect(abs(grew.width / grew.height - frame.width / frame.height) < 0.0001,
               "等比缩放保持宽高比",
               detail: "\(grew.size) vs 原 \(frame.size)")
        // 拖到 (160,60)：宽走满 2×、高只走 1×，取更大的那个 → 2×。
        expect(abs(grew.width - 160) < 0.0001 && abs(grew.height - 120) < 0.0001,
               "等比取两个方向里走得更远的那个",
               detail: "得到 \(grew.size)")

        // 四、左上角：锚点变成右下角，新外框从锚点往左上长。
        let fromTopLeft = SelectionGeometry.resized(
            frame, handle: .topLeft, to: CGPoint(x: -40, y: -30), proportional: true
        )
        expect(fromTopLeft.maxX == 80 && fromTopLeft.maxY == 60,
               "拖左上角时右下角不动",
               detail: "maxX=\(fromTopLeft.maxX) maxY=\(fromTopLeft.maxY)")

        // 五、自由拉伸（Shift）：两个方向各自独立。
        let stretched = SelectionGeometry.resized(
            frame, handle: .bottomRight, to: CGPoint(x: 160, y: 30), proportional: false
        )
        expect(stretched.size == CGSize(width: 160, height: 30),
               "自由拉伸不保持宽高比", detail: "\(stretched.size)")

        // 六、拖过头不翻转，停在最小边长上。
        //
        // 翻转会让图片变成镜像，而镜像在画布上**没有任何视觉提示**——
        // 看起来就是"图坏了"。所以这里只能顶住下限。
        let past = SelectionGeometry.resized(
            frame, handle: .bottomRight, to: CGPoint(x: -50, y: -50), proportional: true
        )
        expect(past.width > 0 && past.height > 0, "拖到锚点另一侧不产生负尺寸",
               detail: "\(past.size)")
        expect(past.origin == CGPoint(x: 0, y: 0), "拖过头时锚点仍然不动")

        let tiny = SelectionGeometry.resized(
            frame, handle: .bottomRight, to: CGPoint(x: 1, y: 1), proportional: true
        )
        expect(abs(min(tiny.width, tiny.height) - SelectionGeometry.minimumSide) < 0.0001,
               "缩到极限时短边正好是下限",
               detail: "\(tiny.size)")
        expect(abs(tiny.width / tiny.height - frame.width / frame.height) < 0.0001,
               "顶下限时**两个方向一起**顶（只顶一边会破坏等比）",
               detail: "\(tiny.size)")

        let tinyFree = SelectionGeometry.resized(
            frame, handle: .bottomRight, to: CGPoint(x: 1, y: 1), proportional: false
        )
        expect(tinyFree.size == CGSize(width: SelectionGeometry.minimumSide,
                                       height: SelectionGeometry.minimumSide),
               "自由拉伸也一样有下限", detail: "\(tinyFree.size)")

        // 七、框选矩形：两个方向都能反向拉，结果必须已标准化。
        let reversed = SelectionGeometry.rect(
            from: CGPoint(x: 10, y: 20), to: CGPoint(x: -10, y: -20)
        )
        expect(reversed == CGRect(x: -10, y: -20, width: 20, height: 40),
               "框选矩形与拖动方向无关", detail: "\(reversed)")
    }

    private static func pointerSelectionAndMarquee() {
        print("点击选择与框选")
        let fixture = makeElementFixture(count: 3)
        let (coordinator, _) = makeCoordinator(scene: fixture.scene)
        let camera = CanvasCamera.initial
        let frames = fixture.ids.map { coordinator.element($0)!.frame }

        // 一、点中元素 = 选中它，并且真的画出外框和四个手柄。
        coordinator.handlePointerDown(pointerInput(world: CGPoint(x: 40, y: 30), camera: camera))
        expect(coordinator.selection == [fixture.ids[0]], "点中元素就选中它",
               detail: shortIDs(Array(coordinator.selection)))
        expect(coordinator.renderedOverlay.selectionFrames == [frames[0]],
               "选中框送到了渲染器")
        expect(coordinator.renderedOverlay.handleFrame == frames[0], "单选时才有手柄")
        expect(coordinator.renderedSelectionBorderCount == 1, "画布上真的画出了一个选中框")
        expect(coordinator.renderedHandleCount == 4, "画布上真的有四个手柄",
               detail: "得到 \(coordinator.renderedHandleCount)")

        // 二、松开。没有越过阈值，所以什么都没挪动。
        coordinator.handlePointerUp(pointerInput(world: CGPoint(x: 40, y: 30), camera: camera))
        expect(coordinator.element(fixture.ids[0])!.frame == frames[0], "点一下不会挪动元素")

        // 二·补、相机一动，选中框要跟着重投影。
        //
        // 覆盖层的位置是世界坐标，屏幕上的位置只有相机知道。少了重投影的表现是：
        // 拖元素时选中框跟着走，但一平移画布，选中框就停在屏幕上不动了——
        // 而它框住的那张图已经跟着画布走了。
        let borderBeforePan = coordinator.renderedSelectionBorderBounds
        var panned = camera
        panned.translate(byViewDelta: CGSize(width: 60, height: 25))
        coordinator.camera = panned
        coordinator.requestRedraw()
        let borderAfterPan = coordinator.renderedSelectionBorderBounds
        expect(
            abs(borderAfterPan.minX - borderBeforePan.minX - 60) < 0.0001
                && abs(borderAfterPan.minY - borderBeforePan.minY - 25) < 0.0001,
            "平移画布后选中框跟着走（不是停在屏幕上）",
            detail: "\(borderBeforePan) → \(borderAfterPan)"
        )
        coordinator.camera = camera
        coordinator.requestRedraw()
        expect(coordinator.renderedSelectionBorderBounds == borderBeforePan,
               "相机转回去，选中框也回到原处")

        // 三、空白处按下 → 清空选择（Figma 惯例），并且进入框选。
        coordinator.handlePointerDown(pointerInput(world: CGPoint(x: -300, y: -200), camera: camera))
        expect(coordinator.selection.isEmpty, "空白处按下清空选择")
        expect(coordinator.renderedSelectionBorderCount == 0, "清空后画布上的选中框也没了")

        // 四、拖出一个盖住全部三个元素的框。
        coordinator.handlePointerDragged(pointerInput(world: CGPoint(x: 250, y: 100), camera: camera))
        expect(coordinator.renderedMarqueeVisible, "框选矩形画出来了")
        expect(coordinator.renderedOverlay.marquee != nil, "框选矩形在覆盖层里")
        expect(coordinator.selection == Set(fixture.ids), "框到哪里选中哪里（实时）",
               detail: shortIDs(Array(coordinator.selection)))
        expect(coordinator.renderedSelectionBorderCount == 3, "三个选中框都画出来了")
        expect(coordinator.renderedOverlay.handleFrame == nil,
               "多选时不画手柄（画出来却拖不动的柄比没有柄更让人困惑）")
        expect(coordinator.renderedHandleCount == 0, "多选时画布上没有手柄")

        // 五、松开：框没了，选择留下。
        coordinator.handlePointerUp(pointerInput(world: CGPoint(x: 250, y: 100), camera: camera))
        expect(!coordinator.renderedMarqueeVisible, "松手后框选矩形消失")
        expect(coordinator.selection == Set(fixture.ids), "松手后选择留下")

        // 六、Shift 点在已选中的元素上 = 把它移出选择。
        coordinator.handlePointerDown(pointerInput(
            world: CGPoint(x: 40, y: 30), camera: camera, modifiers: [.shift]
        ))
        coordinator.handlePointerUp(pointerInput(
            world: CGPoint(x: 40, y: 30), camera: camera, modifiers: [.shift]
        ))
        expect(coordinator.selection == Set([fixture.ids[1], fixture.ids[2]]),
               "Shift 点已选中的元素把它移出选择",
               detail: shortIDs(Array(coordinator.selection)))

        // 七、Shift 框选 = 在原选择上追加，不是替换。
        coordinator.handlePointerDown(pointerInput(
            world: CGPoint(x: -300, y: -200), camera: camera, modifiers: [.shift]
        ))
        coordinator.handlePointerDragged(pointerInput(
            world: CGPoint(x: 20, y: 20), camera: camera, modifiers: [.shift]
        ))
        expect(coordinator.selection.contains(fixture.ids[0]),
               "Shift 框选把新框到的加进来",
               detail: shortIDs(Array(coordinator.selection)))
        expect(coordinator.selection.contains(fixture.ids[1]), "Shift 框选不丢掉原选择")
        coordinator.handlePointerUp(pointerInput(
            world: CGPoint(x: 20, y: 20), camera: camera, modifiers: [.shift]
        ))

        // 八、Escape 清空选择。
        expect(coordinator.handleKeyDown(keyInput(53)), "Escape 被消费（有选择可清）")
        expect(coordinator.selection.isEmpty, "Escape 清空选择")
        expect(coordinator.renderedSelectionBorderCount == 0, "清空后画布上没有选中框")
    }

    private static func elementDragAndResize() {
        print("拖动与缩放元素")
        let fixture = makeElementFixture(count: 3)
        let (coordinator, _) = makeCoordinator(scene: fixture.scene)
        let camera = CanvasCamera.initial
        let original = fixture.ids.map { coordinator.element($0)!.frame }

        // 一、按住元素拖：位移**从按下那一点**算。
        coordinator.handlePointerDown(pointerInput(world: CGPoint(x: 40, y: 30), camera: camera))
        coordinator.handlePointerDragged(pointerInput(world: CGPoint(x: 50, y: 40), camera: camera))
        coordinator.handlePointerDragged(pointerInput(world: CGPoint(x: 60, y: 50), camera: camera))
        expect(coordinator.element(fixture.ids[0])!.frame == original[0].offsetBy(dx: 20, dy: 20),
               "拖到哪就挪到哪（位移从按下时算，不逐帧累加）",
               detail: "\(coordinator.element(fixture.ids[0])!.frame)")
        expect(coordinator.element(fixture.ids[1])!.frame == original[1], "没被选中的元素不动")

        // 二、拖回起点：位移仍然从按下时算，所以正好回到原位。
        coordinator.handlePointerDragged(pointerInput(world: CGPoint(x: 40, y: 30), camera: camera))
        expect(coordinator.element(fixture.ids[0])!.frame == original[0],
               "拖回起点正好回到原位（逐帧累加会漂）",
               detail: "\(coordinator.element(fixture.ids[0])!.frame)")

        coordinator.handlePointerUp(pointerInput(world: CGPoint(x: 40, y: 30), camera: camera))

        // 三、阈值之下不算拖动。**这是另一次按下**：阈值只挡"按下之后有没有
        // 越过"，挡不住已经开始的那次拖动——正在拖的时候当然要跟手。
        let (subThreshold, _) = makeCoordinator(scene: fixture.scene)
        subThreshold.handlePointerDown(pointerInput(world: CGPoint(x: 40, y: 30), camera: camera))
        subThreshold.handlePointerDragged(pointerInput(world: CGPoint(x: 41, y: 31), camera: camera))
        expect(subThreshold.element(fixture.ids[0])!.frame == original[0],
               "没越过阈值不动元素（点一下不会把版面弄歪）",
               detail: "\(subThreshold.element(fixture.ids[0])!.frame)")
        subThreshold.handlePointerUp(pointerInput(world: CGPoint(x: 41, y: 31), camera: camera))

        // 四、Shift 锁轴。
        //
        // 只发**一次**拖动事件：真实拖动会连发几十次，但"第一次就越过阈值"
        // 的那一次同样是一次真实的移动，修饰键必须在那一刻就生效——
        // 第一版 `beginMove` 把修饰键丢了，只有一次事件的拖动不会被锁轴。
        coordinator.handlePointerDown(pointerInput(world: CGPoint(x: 40, y: 30), camera: camera))
        coordinator.handlePointerDragged(pointerInput(
            world: CGPoint(x: 60, y: 45), camera: camera, modifiers: [.shift]
        ))
        expect(coordinator.element(fixture.ids[0])!.frame == original[0].offsetBy(dx: 20, dy: 0),
               "Shift 拖动锁在走得更远的那根轴上",
               detail: "\(coordinator.element(fixture.ids[0])!.frame)")
        coordinator.handlePointerUp(pointerInput(
            world: CGPoint(x: 60, y: 45), camera: camera, modifiers: [.shift]
        ))

        // 五、Shift **从按下的那一刻就按住**，拖一个已选中的元素。
        //
        // 与上面那条只差一处：上面是拖起来之后才按的 Shift，这一条是按下时
        // 就已经按着。而"按住 Shift 把这张图水平挪一下"恰恰是 Shift 最常用的
        // 用法——用户的手在按下那一刻就已经在 Shift 上了。
        //
        // 两条都要有，是因为它们走的是**不同的分支**：上面那条的按下没带 Shift，
        // 走的是"选它、然后拖"；这一条的按下达标就带 Shift，走的是
        // "它已经在选择里，要不要为了锁轴拖动而先把它移出去"。第一版就是在这个
        // 分支上把它移出了选择并直接返回，表现是图先掉出选择、而且拖不动——
        // **上面那条断言在缺陷版本上照样是绿的**，只有这一条会红。
        coordinator.handlePointerDown(pointerInput(
            world: CGPoint(x: 40, y: 30), camera: camera, modifiers: [.shift]
        ))
        expect(coordinator.selection == [fixture.ids[0]],
               "Shift 按在已选中的元素上，按下这一刻不动选择（拖动还要用它）",
               detail: shortIDs(Array(coordinator.selection)))

        coordinator.handlePointerDragged(pointerInput(
            world: CGPoint(x: 60, y: 45), camera: camera, modifiers: [.shift]
        ))
        expect(coordinator.element(fixture.ids[0])!.frame == original[0].offsetBy(dx: 40, dy: 0),
               "Shift 从头按住拖动：元素跟手走，且锁在走得更远的那根轴上",
               detail: "\(coordinator.element(fixture.ids[0])!.frame)")
        expect(coordinator.selection == [fixture.ids[0]],
               "拖起来了就说明这不是一次点击，元素不能被移出选择",
               detail: shortIDs(Array(coordinator.selection)))

        coordinator.handlePointerUp(pointerInput(
            world: CGPoint(x: 60, y: 45), camera: camera, modifiers: [.shift]
        ))
        expect(coordinator.selection == [fixture.ids[0]],
               "Shift 拖动松手后元素仍在选择里（移出选择只留给没拖动的那次点击）",
               detail: shortIDs(Array(coordinator.selection)))

        // 六、多选整组拖动：一次命令带一组外框。
        //
        // 循环 `setFrame` 的话，一帧里每个元素各触发一次 SwiftUI 更新——
        // 拖 20 个元素就是每帧 20 次。这条断言钉的是"一帧一次"。
        var changeCount = 0
        let (grouped, _) = makeCoordinator(
            scene: fixture.scene,
            selection: Set(fixture.ids),
            onSceneChange: { _ in changeCount += 1 }
        )
        grouped.handlePointerDown(pointerInput(world: CGPoint(x: 40, y: 30), camera: camera))
        grouped.handlePointerDragged(pointerInput(world: CGPoint(x: 50, y: 30), camera: camera))
        changeCount = 0
        grouped.handlePointerDragged(pointerInput(world: CGPoint(x: 60, y: 30), camera: camera))
        expect(changeCount == 1,
               "多选拖动一帧只通知一次（不是每个元素一次）",
               detail: "得到 \(changeCount) 次")
        for (index, id) in fixture.ids.enumerated() {
            expect(grouped.element(id)!.frame == original[index].offsetBy(dx: 20, dy: 0),
                   "整组一起挪：第 \(index + 1) 个")
        }

        // 七、拖手柄缩放，锚点是对角线那一头。
        //
        // 按下的那一点**正好是外框的右下角**，它同时也在元素内部，所以这一条
        // 顺带验了"手柄判定优先于元素判定"——反过来的话这里会变成拖动元素，
        // 表现是"抓住手柄却把图挪走了"。
        let (resizer, _) = makeCoordinator(scene: fixture.scene, selection: [fixture.ids[0]])
        resizer.handlePointerDown(pointerInput(world: CGPoint(x: 80, y: 60), camera: camera))
        expect(resizer.isResizingElement, "按在外框角上进入的是缩放，不是拖动")
        resizer.handlePointerDragged(pointerInput(world: CGPoint(x: 160, y: 60), camera: camera))
        let resized = resizer.element(fixture.ids[0])!.frame
        expect(resized.origin == CGPoint(x: 0, y: 0), "缩放时对角固定不动",
               detail: "origin=\(resized.origin)")
        expect(abs(resized.width - 160) < 0.0001 && abs(resized.height - 120) < 0.0001,
               "默认等比：拖宽一倍，高也跟着一倍",
               detail: "\(resized.size)")
        resizer.handlePointerUp(pointerInput(world: CGPoint(x: 160, y: 60), camera: camera))

        // 八、Shift 缩放 = 自由拉伸。
        let (free, _) = makeCoordinator(scene: fixture.scene, selection: [fixture.ids[0]])
        free.handlePointerDown(pointerInput(world: CGPoint(x: 80, y: 60), camera: camera))
        free.handlePointerDragged(pointerInput(
            world: CGPoint(x: 160, y: 30), camera: camera, modifiers: [.shift]
        ))
        expect(free.element(fixture.ids[0])!.frame.size == CGSize(width: 160, height: 30),
               "Shift 缩放是自由拉伸",
               detail: "\(free.element(fixture.ids[0])!.frame.size)")

        // 九、多选时点其中一个：按下不收缩，松手才收缩。
        //
        // 先收缩的话，多选之后想整体挪一下就每次都得重新框一遍。
        let (collapse, _) = makeCoordinator(scene: fixture.scene, selection: Set(fixture.ids))
        collapse.handlePointerDown(pointerInput(world: CGPoint(x: 40, y: 30), camera: camera))
        expect(collapse.selection == Set(fixture.ids),
               "多选时按下不立刻收缩（否则拖不动整组）")
        collapse.handlePointerUp(pointerInput(world: CGPoint(x: 40, y: 30), camera: camera))
        expect(collapse.selection == [fixture.ids[0]], "松手时才收缩成点中的那一个")
    }

    /// 一次用户手势。
    ///
    /// **撤销分组由我们手动划定**：自检里从头到尾都在同一个事件里，没有运行
    /// 循环可转，`UndoManager` 的"按事件自动分组"会把几十次登记并成一组，
    /// 于是一次 `undo()` 全都退了——那测的就不是"一次操作一条记录"了。
    /// （产品里自动分组是开着的，而且正合适：每次鼠标事件之间运行循环都会
    /// 转一圈，一次手势恰好落进一组。）
    private static func gesture(_ undo: UndoManager?, _ body: () -> Void) {
        undo?.beginUndoGrouping()
        body()
        undo?.endUndoGrouping()
    }

    /// 菜单发出去的那一下到底有没有走到画布上（Codex 复审 P0 #3）。
    ///
    /// 这一条**必须走真窗口的响应链**，不能直接调 `coordinator.undo()`：
    /// 缺陷的形态恰恰是"画布上的实现是对的，只是没人走到它"——直接调等于绕开了
    /// 唯一会出问题的那一段。
    ///
    /// 判据是**图有没有被撤回去**，不是"方法在不在"。`tryToPerform` 返回 true
    /// 只说明选择器被接住了；接住之后什么都不做的实现照样能让它返回 true，
    /// 所以两条都要有。
    private static func responderChainActionsAreWired() {
        print("响应链动作（P0 #3）")

        let fixture = makeElementFixture(count: 1)
        let camera = CanvasCamera.initial
        let (coordinator, view, window) = makeWindowedCoordinator(scene: fixture.scene)
        defer { window.close() }

        guard let undoManager = view.window?.undoManager else {
            expect(false, "测试窗口有撤销管理器（没有它测的不是产品那条路）")
            return
        }

        // 先做一次真的能撤销的操作：把唯一的元素拖走。
        //
        // 必须用 `gesture` 包起来：测试窗口的 `groupsByEvent` 是关掉的（见
        // `makeWindowedCoordinator`），不开组就登记会直接抛异常。
        let original = coordinator.element(fixture.ids[0])!.frame
        gesture(undoManager) {
            coordinator.handlePointerDown(pointerInput(world: CGPoint(x: 40, y: 30), camera: camera))
            coordinator.handlePointerDragged(pointerInput(world: CGPoint(x: 100, y: 30), camera: camera))
            coordinator.handlePointerUp(pointerInput(world: CGPoint(x: 100, y: 30), camera: camera))
        }
        let moved = coordinator.element(fixture.ids[0])!.frame
        expect(moved != original, "先真的把元素拖走了（否则下面撤的是什么就说不清）",
               detail: "\(moved)")
        expect(undoManager.canUndo, "窗口的撤销栈里现在有一条")
        // 栈是空的话 `undo()` 会抛，那样这一组会**崩**而不是报红——
        // 崩了后面的断言一条都不跑，问题被藏起来。所以这里先退出去。
        guard undoManager.canUndo else { return }

        // 画布进窗口时会自己抢第一响应者（`viewDidMoveToWindow`），这里确认一下：
        // 它不在链头的话，菜单发出去的那一下根本到不了它。
        expect(window.firstResponder === view, "画布在响应链的头上")

        // 菜单发的那一下。选择器从**菜单用的那个常量**取——
        // 测试自己另写一遍的话，菜单写歪了这里照样绿，等于没测。
        let handled = window.firstResponder?.tryToPerform(CanvasResponderAction.undo, with: nil) ?? false
        expect(handled, "画布接住了菜单发的这个选择器")
        expect(coordinator.element(fixture.ids[0])!.frame == original,
               "接住之后真的撤回去了（接住但不做事的实现也会让上一条绿）",
               detail: "\(coordinator.element(fixture.ids[0])!.frame)")

        // 反向那一条：不带冒号的 `undo` 是**另一个选择器**，画布不认它。
        // 这正是缺陷的形态——菜单发它、落到空处，而且不报错、编译也过。
        expect(!(window.firstResponder?.tryToPerform(#selector(UndoManager.undo), with: nil) ?? false),
               "不带冒号的 undo 画布不认（菜单发这个就是静默落到空处）")

        // 重做同理：只断言 `canRedo` 而不真的走一次，抓不到"反向快照过期"那类缺陷。
        let redone = window.firstResponder?.tryToPerform(CanvasResponderAction.redo, with: nil) ?? false
        expect(redone, "画布接住了重做的选择器")
        expect(coordinator.element(fixture.ids[0])!.frame == moved,
               "重做把元素放回拖走后的位置",
               detail: "\(coordinator.element(fixture.ids[0])!.frame)")
    }

    private static func undoOfDirectManipulation() {
        print("撤销与重做（直接操控）")

        let fixture = makeElementFixture(count: 3)
        let (coordinator, view, window) = makeWindowedCoordinator(scene: fixture.scene)
        defer { window.close() }
        guard let undo = view.window?.undoManager else {
            expect(false, "测试窗口有撤销管理器")
            return
        }
        let camera = CanvasCamera.initial
        let original = fixture.ids.map { coordinator.element($0)!.frame }

        // 一、一次拖动 = 一条撤销记录。
        gesture(undo) {
            coordinator.handlePointerDown(pointerInput(world: CGPoint(x: 40, y: 30), camera: camera))
            for step in 1...10 {
                coordinator.handlePointerDragged(pointerInput(
                    world: CGPoint(x: 40 + CGFloat(step) * 5, y: 30), camera: camera
                ))
            }
            coordinator.handlePointerUp(pointerInput(world: CGPoint(x: 90, y: 30), camera: camera))
        }
        expect(coordinator.element(fixture.ids[0])!.frame == original[0].offsetBy(dx: 50, dy: 0),
               "拖完停在手指的位置")
        expect(undo.canUndo, "拖动之后有东西可撤销")
        undo.undo()
        expect(coordinator.element(fixture.ids[0])!.frame == original[0],
               "撤销一次就回到拖动之前（不是退 10 次）",
               detail: "\(coordinator.element(fixture.ids[0])!.frame)")
        expect(undo.canRedo, "撤销之后有东西可重做")
        undo.redo()
        expect(coordinator.element(fixture.ids[0])!.frame == original[0].offsetBy(dx: 50, dy: 0),
               "重做回到拖动之后")
        undo.undo()

        // 二、缩放也登记。
        coordinator.handleKeyDown(keyInput(53))          // Escape 清空选择
        // 先点选、再缩放是两个用户事件；选择本身现在也可撤销，不能在这个
        // 人工合并的“缩放手势”分组里把它一起撤掉。
        gesture(undo) {
            coordinator.handlePointerDown(pointerInput(world: CGPoint(x: 40, y: 30), camera: camera))
            coordinator.handlePointerUp(pointerInput(world: CGPoint(x: 40, y: 30), camera: camera))
        }
        gesture(undo) {
            coordinator.handlePointerDown(pointerInput(world: CGPoint(x: 80, y: 60), camera: camera))
            coordinator.handlePointerDragged(pointerInput(world: CGPoint(x: 160, y: 60), camera: camera))
            coordinator.handlePointerUp(pointerInput(world: CGPoint(x: 160, y: 60), camera: camera))
        }
        expect(coordinator.element(fixture.ids[0])!.frame != original[0], "缩放改了外框")
        undo.undo()
        expect(coordinator.element(fixture.ids[0])!.frame == original[0], "撤销缩放",
               detail: "\(coordinator.element(fixture.ids[0])!.frame)")

        // 三、方向键微移：一次按下 = 一条记录。
        //
        // 两次按下是两次手势，所以是两条记录、两次撤销——不是"撤一次退两步"。
        // 产品里靠的是两次按键之间运行循环转了一圈、自动分组把它们分开。
        gesture(undo) { coordinator.handleKeyDown(keyInput(124)) }   // →
        let afterOne = coordinator.element(fixture.ids[0])!.frame
        expect(afterOne == original[0].offsetBy(dx: SelectionController.nudgeStep, dy: 0),
               "方向键微移一个步长",
               detail: "\(afterOne)")
        gesture(undo) { coordinator.handleKeyDown(keyInput(124, modifiers: [.shift])) }
        expect(coordinator.element(fixture.ids[0])!.frame
                == afterOne.offsetBy(dx: SelectionController.nudgeStep * 10, dy: 0),
               "Shift + 方向键是十倍步长（从当前落点算，不是从原点多走十步）",
               detail: "\(coordinator.element(fixture.ids[0])!.frame)")
        undo.undo()
        expect(coordinator.element(fixture.ids[0])!.frame == afterOne,
               "撤销一次退掉的是 Shift 那一步",
               detail: "\(coordinator.element(fixture.ids[0])!.frame)")
        undo.undo()
        expect(coordinator.element(fixture.ids[0])!.frame == original[0],
               "再撤销一次退掉第一次微移",
               detail: "\(coordinator.element(fixture.ids[0])!.frame)")

        // 四、自动重复不再单独登记。
        //
        // 按住方向键会连发几十次；每次登记一条的话，撤销要按几十下才退得回去。
        // 基准取"这一段开始之前"的位置，不是最原始的位置——上一步的微移
        // 已经撤销过一轮，此刻的落点不是 `original`。
        let beforeRepeat = coordinator.element(fixture.ids[0])!.frame
        gesture(undo) {
            coordinator.handleKeyDown(keyInput(124))
            for _ in 0..<20 {
                coordinator.handleKeyDown(keyInput(124, isARepeat: true))
            }
        }
        expect(coordinator.element(fixture.ids[0])!.frame
                == beforeRepeat.offsetBy(dx: SelectionController.nudgeStep * 21, dy: 0),
               "连发 21 次 = 21 个步长",
               detail: "\(coordinator.element(fixture.ids[0])!.frame)")
        undo.undo()
        expect(coordinator.element(fixture.ids[0])!.frame == beforeRepeat,
               "按住方向键连发 20 次，撤销一次全退掉",
               detail: "\(coordinator.element(fixture.ids[0])!.frame)")

        // 五、删除的撤销要**连层序一起**回来。
        //
        // 用 `insert` 做逆操作的话，放回来的元素会排到最上面——撤销一次删除，
        // 层序却变了，而"层序变了"在一堆叠起来的图上看起来就是另一张图。
        var layered = CanvasScene()
        for id in fixture.ids {
            layered.insert(CanvasElement(
                id: id, kind: .image(asset: fixture.asset),
                frame: CGRect(x: 0, y: 0, width: 40, height: 40), order: 0
            ))
        }
        layered.bringToFront([fixture.ids[0]])
        let (layeredCoordinator, _, layeredWindow) = makeWindowedCoordinator(scene: layered)
        defer { layeredWindow.close() }
        let orderBefore = layeredCoordinator.scene.elements.map(\.id)
        expect(orderBefore.last == fixture.ids[0], "前置过的元素确实排在最上面")

        // 同理，点击选择与按 Delete 是两个操作；后者撤销后应恢复前者的选择。
        gesture(layeredWindow.undoManager) {
            layeredCoordinator.handlePointerDown(pointerInput(world: CGPoint(x: 20, y: 20), camera: camera))
            layeredCoordinator.handlePointerUp(pointerInput(world: CGPoint(x: 20, y: 20), camera: camera))
        }
        gesture(layeredWindow.undoManager) {
            expect(layeredCoordinator.handleKeyDown(keyInput(51)), "Delete 被消费")
        }
        expect(layeredCoordinator.scene.elements.count == 2, "元素被删掉了")
        expect(layeredCoordinator.selection.isEmpty, "删完选择也空了")

        layeredWindow.undoManager?.undo()
        expect(layeredCoordinator.scene.elements.map(\.id) == orderBefore,
               "撤销删除后层序与删除前逐位一致",
               detail: "\(shortIDs(layeredCoordinator.scene.elements.map(\.id)))")
        expect(layeredCoordinator.selection == [fixture.ids[0]],
               "撤销删除后选中的是放回来的那个")

        layeredWindow.undoManager?.redo()
        expect(layeredCoordinator.scene.elements.count == 2, "重做又把元素删掉了")

        // 六、撤销之后覆盖层跟着走（框不能停在原地）。
        layeredWindow.undoManager?.undo()
        expect(layeredCoordinator.renderedSelectionBorderCount == 1,
               "撤销后选中框跟着元素回来",
               detail: "得到 \(layeredCoordinator.renderedSelectionBorderCount)")

        // 七、换画布清空撤销栈：栈里的记录属于另一块画布。
        coordinator.applySceneFromOutside(CanvasScene())
        expect(!undo.canUndo, "换画布后撤销栈被清空")
    }

    /// 选择不再只是视觉状态：单击、Escape、框选都走同一份窗口历史；容量则由
    /// 配置对象注入真实的 `UndoManager`，不是散落在手势控制器里的魔法数字。
    private static func selectionUndoAndHistoryLimit() {
        print("选择撤销与历史容量")

        let fixture = makeElementFixture(count: 2)
        let (coordinator, view, window) = makeWindowedCoordinator(scene: fixture.scene)
        defer { window.close() }
        guard let undo = view.window?.undoManager else {
            expect(false, "选择撤销测试窗口有撤销管理器")
            return
        }
        expect(undo.levelsOfUndo == CanvasUndoConfiguration.default.maximumSteps,
               "窗口撤销容量来自可配置的默认值（15 步）",
               detail: "得到 \(undo.levelsOfUndo)")

        let camera = CanvasCamera.initial
        gesture(undo) {
            coordinator.handlePointerDown(pointerInput(world: CGPoint(x: 40, y: 30), camera: camera))
            coordinator.handlePointerUp(pointerInput(world: CGPoint(x: 40, y: 30), camera: camera))
        }
        expect(coordinator.selection == [fixture.ids[0]], "点击会选中元素")
        undo.undo()
        expect(coordinator.selection.isEmpty, "⌘Z 可撤回一次点击选择")
        undo.redo()
        expect(coordinator.selection == [fixture.ids[0]], "⌘⇧Z 可重做选择")

        gesture(undo) {
            expect(coordinator.handleKeyDown(keyInput(53)), "Escape 清除选择会被消费")
        }
        expect(coordinator.selection.isEmpty, "Escape 清除当前选择")
        undo.undo()
        expect(coordinator.selection == [fixture.ids[0]], "撤销 Escape 恢复选择")

        gesture(undo) { _ = coordinator.deleteElement(fixture.ids[0]) }
        expect(coordinator.scene.element(fixture.ids[0]) == nil, "上下文删除进入场景命令")
        undo.undo()
        expect(coordinator.scene.element(fixture.ids[0]) != nil, "撤销上下文删除恢复元素")
        expect(coordinator.selection == [fixture.ids[0]], "撤销上下文删除恢复删除前选择")
    }

    private static func panModesAndCursor() {
        print("平移方式与光标反馈")

        let fixture = makeElementFixture(count: 2)
        let (coordinator, _) = makeCoordinator(scene: fixture.scene)
        let camera = CanvasCamera.initial
        let startCenter = coordinator.camera.center

        // 一、空白拖动 = 框选，**不是**平移。产品负责人 2026-09-18 定的分工。
        coordinator.handlePointerDown(pointerInput(world: CGPoint(x: -300, y: -200), camera: camera))
        coordinator.handlePointerDragged(pointerInput(world: CGPoint(x: -250, y: -150), camera: camera))
        expect(coordinator.camera.center == startCenter,
               "空白拖动不动相机（它现在是框选）",
               detail: "\(coordinator.camera.center)")
        expect(coordinator.renderedMarqueeVisible, "空白拖动拉出的是框选矩形")
        coordinator.handlePointerUp(pointerInput(world: CGPoint(x: -250, y: -150), camera: camera))

        // 二、按住空格：左键拖动变成平移，光标先变成张开的手。
        expect(coordinator.handleKeyDown(keyInput(49)), "空格被消费（进入待平移）")
        expect(coordinator.isSpacePanReady, "进入待平移状态")
        expect(coordinator.currentCursor == .openHand,
               "待平移时指针是张开的手（按下之前就要有信号）",
               detail: "\(coordinator.currentCursor)")

        let selectionBefore = coordinator.selection
        coordinator.handlePointerDown(pointerInput(world: CGPoint(x: 40, y: 30), camera: camera))
        expect(coordinator.isPanningCanvas, "空格 + 左键按下进入平移")
        expect(coordinator.currentCursor == .closedHand, "拖动中指针是握住的手")
        expect(coordinator.selection == selectionBefore,
               "空格平移不会顺带改选择（在元素上按下也不选中）")
        coordinator.handlePointerDragged(pointerInput(world: CGPoint(x: 90, y: 30), camera: camera))
        expect(coordinator.camera.center == CGPoint(x: startCenter.x - 50, y: startCenter.y),
               "画布跟着手指走",
               detail: "\(coordinator.camera.center)")
        coordinator.handlePointerUp(pointerInput(world: CGPoint(x: 90, y: 30), camera: camera))
        expect(!coordinator.isPanningCanvas, "松手即停（不加第二套惯性）")

        // 三、松开空格退出待平移。
        //
        // 没有 keyUp 的话，空格按一下之后**永远**在平移，而且看不出原因——
        // 所以宿主必须转发 keyUp，这一条断言钉的就是它。
        coordinator.handleKeyUp(keyInput(49))
        expect(!coordinator.isSpacePanReady, "松开空格退出待平移")
        expect(coordinator.currentCursor == .arrow, "退出后指针恢复箭头")

        // 四、中键拖动也是平移，且与空格无关。
        let centerBeforeMiddle = coordinator.camera.center
        coordinator.handlePointerDown(pointerInput(
            world: CGPoint(x: 0, y: 0), camera: coordinator.camera, button: .other
        ))
        expect(coordinator.isPanningCanvas, "中键按下进入平移")
        coordinator.handlePointerDragged(pointerInput(
            world: CGPoint(x: 30, y: 0), camera: coordinator.camera, button: .other
        ))
        expect(coordinator.camera.center == CGPoint(x: centerBeforeMiddle.x - 30,
                                                    y: centerBeforeMiddle.y),
               "中键平移生效")
        coordinator.handlePointerUp(pointerInput(
            world: CGPoint(x: 30, y: 0), camera: coordinator.camera, button: .other
        ))
        expect(!coordinator.isPanningCanvas, "中键松手即停")

        // 五、手柄上的指针是十字。
        coordinator.handlePointerDown(pointerInput(world: CGPoint(x: 40, y: 30), camera: camera))
        coordinator.handlePointerUp(pointerInput(world: CGPoint(x: 40, y: 30), camera: camera))
        let frame = coordinator.element(fixture.ids[0])!.frame
        let corner = SelectionGeometry.handleCenters(
            of: frame, camera: coordinator.camera
        )[.bottomRight]!
        coordinator.handlePointerMoved(pointerInput(
            world: coordinator.camera.viewToWorld(corner), camera: coordinator.camera
        ))
        expect(coordinator.currentCursor == .crosshair,
               "悬停在手柄上是十字（不提示的话用户不知道自己抓住了）",
               detail: "\(coordinator.currentCursor)")

        let away = coordinator.camera.viewToWorld(CGPoint(x: corner.x + 60, y: corner.y + 60))
        coordinator.handlePointerMoved(pointerInput(world: away, camera: coordinator.camera))
        expect(coordinator.currentCursor == .arrow, "离开手柄恢复箭头")
    }

    private static func canvasToolbarBasics() {
        print("画布工具栏基础操作")
        let fixture = makeElementFixture(count: 2)
        var motion = MotionConfiguration.default
        motion.reduceMotion = true
        let (coordinator, view) = makeCoordinator(
            scene: fixture.scene,
            selection: [fixture.ids[0]],
            configuration: motion
        )

        coordinator.setTool(.hand)
        expect(coordinator.currentCursor == .openHand, "切到抓手后显示张开的手")
        let selectedBefore = coordinator.selection
        let sceneBefore = coordinator.scene
        let centerBefore = coordinator.camera.center
        let start = pointerInput(world: CGPoint(x: 40, y: 30), camera: coordinator.camera)
        coordinator.handlePointerDown(start)
        expect(coordinator.isPanningCanvas, "抓手在图片上按下仍进入平移")
        expect(coordinator.currentCursor == .closedHand, "抓手拖动时显示握住的手")
        coordinator.handlePointerDragged(pointerInput(
            world: CGPoint(x: 90, y: 30), camera: coordinator.camera
        ))
        coordinator.handlePointerUp(pointerInput(
            world: CGPoint(x: 90, y: 30), camera: coordinator.camera
        ))
        expect(coordinator.camera.center.x == centerBefore.x - 50, "抓手拖动画布 50 点")
        expect(coordinator.selection == selectedBefore, "抓手不改变图片选择")
        expect(coordinator.scene == sceneBefore, "抓手不移动图片")
        expect(coordinator.currentCursor == .openHand, "抓手松开后恢复张开的手")

        coordinator.setTool(.select)
        expect(coordinator.currentCursor == .arrow, "切回选择工具恢复箭头")
        let next = pointerInput(world: CGPoint(x: 140, y: 30), camera: coordinator.camera)
        coordinator.handlePointerDown(next)
        coordinator.handlePointerUp(next)
        expect(coordinator.selection == [fixture.ids[1]], "切回选择工具可选择另一张图片")

        let selectedFrame = fixture.scene.element(fixture.ids[1])!.frame
        var expected = coordinator.camera
        expected.fit(worldRect: selectedFrame)
        coordinator.focusSelection()
        expect(coordinator.camera.center == expected.center && coordinator.camera.zoom == expected.zoom,
               "定位选中内容只围绕选中的图片")

        view.showsGrid = false
        expect(!view.showsGrid, "网格可隐藏且不影响画布内容")
        view.showsGrid = true
        expect(view.showsGrid, "网格可重新显示")
    }

    // MARK: - 手感参数

    /// 手感参数必须**真的被消费**。
    ///
    /// 这一组断言的存在理由，是本项目已经踩过两次的同一类问题：
    /// **参数在那儿但没接线**。把数字从调用点搬进配置之后，"接线"变成了
    /// 一件需要证据的事——每条参数都注入一个和默认值**明显不同**的值，
    /// 再断言行为跟着变。没有这一层，搬进配置只是把字面量换了个地方写。
    ///
    /// 为什么覆盖得到：`handleScroll` / `handleMagnify` / `handleZoomStep`
    /// 走的是真实事件**委托之后完全相同**的那条路。
    private static func feelConfigurationIsWired() {
        print("手感参数接线")

        // 平移倍率：同样的滚动增量，倍率 4 应当走 4 倍远。
        let baseline = scrollDisplacement(panSpeed: 1)
        let quadrupled = scrollDisplacement(panSpeed: 4)
        expect(baseline > 0, "默认平移确实动了", detail: "位移 \(baseline)")
        expect(abs(quadrupled - baseline * 4) < 1e-6,
               "平移倍率生效", detail: "1× 走 \(baseline)，4× 走 \(quadrupled)")

        // 非精确设备（鼠标滚轮）另有一个行→点换算。默认是 1（不换算，
        // 保持批次 A 行为），所以要注入一个非 1 的值才验得出这条支路活着。
        let wheel = scrollDisplacement(panSpeed: 1, linesToPoints: 3, isPrecise: false)
        expect(abs(wheel - baseline * 3) < 1e-6,
               "鼠标滚轮的行→点换算生效", detail: "得到 \(wheel)，期望 \(baseline * 3)")

        // 捏合灵敏度：放大 10%，灵敏度 2 应当放大约 20%。
        expect(abs(zoomAfterMagnify(magnification: 0.1, sensitivity: 1) - 1.1) < 1e-9,
               "捏合按原始增量（灵敏度 1 时正好 1.1 倍）")
        expect(abs(zoomAfterMagnify(magnification: 0.1, sensitivity: 2) - 1.2) < 1e-9,
               "捏合灵敏度生效", detail: "得到 \(zoomAfterMagnify(magnification: 0.1, sensitivity: 2))")

        // ⌘ + 滚动缩放：每点增量对应的比例变化。
        expect(abs(zoomAfterCommandScroll(delta: 20, sensitivity: 0.05) - 2) < 1e-9,
               "⌘+滚轮按 sensitivity 缩放", detail: "期望 2.0")
        expect(abs(zoomAfterCommandScroll(delta: 20, sensitivity: 0.025) - 1.5) < 1e-9,
               "改了 sensitivity 结果跟着变")

        // 步进倍数：按钮与菜单读的就是这个值。这里验的是"值真的进了缩放路径"
        // ——界面上的消费点（工具条、菜单）没有断言，只有编译期引用。
        var instant = MotionConfiguration.default
        instant.programmaticCameraDuration = 0        // 不走缓动，同步拿终态
        instant.feel.zoomStepFactor = 2
        let (stepped, _) = makeCoordinator(scene: CanvasScene(), configuration: instant)
        let afterStep = stepped.handleZoomStep(instant.feel.zoomStepFactor)
        expect(abs(afterStep.zoom - CanvasCamera.initial.zoom * 2) < 1e-6,
               "步进倍数进了缩放路径", detail: "得到 \(afterStep.zoom)")
    }

    /// 缓动配置里那几个数字也要真的起作用。
    private static func motionAnimationsReachTheTarget() async {
        print("缓动参数接线")

        // 「降低动态效果」= 直接跳到终态，不播动画。
        var reduced = MotionConfiguration.default
        reduced.reduceMotion = true
        let (reducedCoordinator, _) = makeCoordinator(scene: CanvasScene(), configuration: reduced)
        let jumped = reducedCoordinator.handleZoomStep(2)
        expect(abs(jumped.zoom - CanvasCamera.initial.zoom * 2) < 1e-9,
               "降低动态效果：直接到终态", detail: "得到 \(jumped.zoom)")

        // 帧间隔：它决定缓动推进的节奏。
        //
        // ## 为什么是数帧数，而不是量"同一时刻推进了多少"
        //
        // 前两版都在量位置，两版都自己红过：
        //
        // 1. 第一版断言"慢的那侧 40ms 内推进 < 1%"，跑出来正好 1%。原因不是代码，
        //    是这条线画在了噪声上——循环第一帧的 `elapsed` 是从 `CACurrentMediaTime()`
        //    到 Task 真被调度之间那点延迟，随机器忙闲浮动，1ms 就对应约 3% 推进。
        // 2. 第二版改成两侧推进量的**比值**（自归一化），看着更稳，其实没解决问题：
        //    "慢"的那侧 40ms 里只跑了一帧，那一帧的 `elapsed` 就是调度延迟，
        //    于是慢侧量到的**仍然是机器的忙闲**。它在今天第三次跑红：慢 40% / 快 143%，
        //    比值 3.6 < 5。阈值不是被代码撞破的，是被调度延迟撞破的。
        //
        // 两个数之间要差一个数量级才谈得上"阈值"，所以改成直接数帧数：窗口取得比
        // 慢间隔短，慢侧就**最多**一帧（这是结构决定的，与忙闲无关）；快间隔那侧
        // 是一二十帧。慢侧的上界因此从"量出来的"变成"推出来的"。
        //
        // ## 窗口为什么从 40ms 放长到 100ms
        //
        // 快侧那条 `>= 8` 仍然是个绝对数，它的余量取决于"每次 `Task.sleep(2ms)`
        // 实际花多久"：40ms 的窗口里要凑够 8 帧，等于假设每帧不超过 5ms——只有
        // 2.5 倍余量，而这类余量正是前面两版翻车的地方。窗口放到 100ms 之后，
        // 同样的 8 帧允许每帧 12.5ms，余量 6 倍。慢侧不受影响：窗口仍然远小于
        // 它的间隔，上界照样是 1。
        let slowFrames = await framesEmitted(frameInterval: 0.4, window: 0.1)
        let fastFrames = await framesEmitted(frameInterval: 0.002, window: 0.1)
        expect(slowFrames <= 1,
               "帧间隔 400ms：100ms 窗口里最多推一帧（窗口比间隔短）",
               detail: "推了 \(slowFrames) 帧")
        expect(fastFrames >= 8,
               "帧间隔 2ms：100ms 窗口里推了很多帧",
               detail: "推了 \(fastFrames) 帧")
        expect(fastFrames > slowFrames * 5,
               "帧间隔确实在控制节奏（快的那侧多一个数量级）",
               detail: "慢 \(slowFrames) 帧 / 快 \(fastFrames) 帧")

        // 缓动最终要落到终态，不能停在半路。
        var smooth = MotionConfiguration.default
        smooth.programmaticCameraDuration = 0.1
        let (coordinator, _) = makeCoordinator(scene: CanvasScene(), configuration: smooth)
        coordinator.handleZoomStep(2)
        let arrived = await waitUntil("缓动落到终态") {
            abs(coordinator.camera.zoom - CanvasCamera.initial.zoom * 2) < 1e-6
        }
        expect(arrived, "缓动结束后停在目标倍率",
               detail: "得到 \(coordinator.camera.zoom)")
    }

    /// 同样的滚动增量在给定平移倍率下走多远（视图点）。
    private static func scrollDisplacement(
        panSpeed: CGFloat,
        linesToPoints: CGFloat = 1,
        isPrecise: Bool = true
    ) -> CGFloat {
        var configuration = MotionConfiguration.default
        configuration.feel.panSpeed = panSpeed
        configuration.feel.mouseWheelLinesToPoints = linesToPoints
        let (coordinator, _) = makeCoordinator(scene: CanvasScene(), configuration: configuration)
        let before = coordinator.camera.center
        let after = coordinator.handleScroll(CanvasScrollInput(
            viewPoint: CGPoint(x: 400, y: 300),
            worldPoint: .zero,
            delta: CGSize(width: 0, height: -50),
            isPrecise: isPrecise,
            phase: .changed,
            momentumPhase: .none,
            modifiers: []
        ))
        // 世界位移 × 缩放 = 视图点位移。
        return abs(after.center.y - before.y) * after.zoom
    }

    /// 捏合一次之后的缩放倍率。
    private static func zoomAfterMagnify(magnification: CGFloat, sensitivity: CGFloat) -> CGFloat {
        var configuration = MotionConfiguration.default
        configuration.feel.magnifySensitivity = sensitivity
        let (coordinator, _) = makeCoordinator(scene: CanvasScene(), configuration: configuration)
        let after = coordinator.handleMagnify(CanvasMagnifyInput(
            viewPoint: CGPoint(x: 400, y: 300),
            worldPoint: .zero,
            magnification: magnification,
            phase: .changed,
            modifiers: []
        ))
        return after.zoom / CanvasCamera.initial.zoom
    }

    /// ⌘ + 滚动一次之后的缩放倍率。
    private static func zoomAfterCommandScroll(delta: CGFloat, sensitivity: CGFloat) -> CGFloat {
        var configuration = MotionConfiguration.default
        configuration.feel.commandScrollZoomSensitivity = sensitivity
        let (coordinator, _) = makeCoordinator(scene: CanvasScene(), configuration: configuration)
        let after = coordinator.handleScroll(CanvasScrollInput(
            viewPoint: CGPoint(x: 400, y: 300),
            worldPoint: .zero,
            delta: CGSize(width: 0, height: delta),
            isPrecise: true,
            phase: .changed,
            momentumPhase: .none,
            modifiers: [.command]
        ))
        return after.zoom / CanvasCamera.initial.zoom
    }

    /// 数一数：给定帧间隔下，窗口内缓动真正推进了几帧。
    ///
    /// 这里**不经过协调器**，直接给 `InputController` 一个只会计数的
    /// `CanvasContext`。走的是和真实宿主相同的代码路径（适配器只认协议），
    /// 但"推了几帧"变成了直接读一个计数器，而不是从相机位置反推。
    private static func framesEmitted(frameInterval: TimeInterval, window: TimeInterval) async -> Int {
        var configuration = MotionConfiguration.default
        configuration.programmaticCameraDuration = 0.1
        configuration.feel.animationFrameInterval = frameInterval
        let context = FrameCountingContext(configuration: configuration)
        let adapter = InputController()
        adapter.zoomStep(4, context: context)
        try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
        return context.cameraWrites
    }
}

/// 只用来数帧的 `CanvasContext`。
///
/// 自检里第一版是拿"同一时刻推进了多少"去反推帧间隔有没有生效的，那条路会随
/// 主 actor 的调度延迟浮动：节奏"慢"的那一侧在 40ms 里只跑了一帧，而那一帧的
/// `elapsed` 里含的是 Task 被调度的延迟，于是**慢的那侧量到的其实是机器的忙闲**。
///
/// 直接数帧数就没有这个问题：间隔 200ms 时，40ms 的窗口里无论机器多忙都只可能
/// 推进一帧；间隔 2ms 时是一二十帧。两个数差一个数量级，而不是靠比值去卡。
///
/// 之所以能这么写，是因为协议注释本来就承诺"交互逻辑可以在测试里构造输入直接
/// 断言"——这个类就是那句话的兑现：适配器从协议里拿相机，不关心背后是渲染器
/// 还是这个计数器。
@MainActor
private final class FrameCountingContext: CanvasContext {
    /// 相机被写入的次数 = 缓动推出去的帧数。
    private(set) var cameraWrites = 0

    private var storedCamera = CanvasCamera.initial
    private let configuration: MotionConfiguration

    init(configuration: MotionConfiguration) {
        self.configuration = configuration
    }

    var camera: CanvasCamera {
        get { storedCamera }
        set {
            cameraWrites += 1
            storedCamera = newValue
        }
    }

    var viewportSize: CGSize { storedCamera.viewportSize }
    var motionConfiguration: MotionConfiguration { configuration }

    var scene = CanvasScene()
    func element(_ id: CanvasElementID) -> CanvasElement? { nil }
    func hitTest(worldPoint: CGPoint) -> CanvasElementID? { nil }
    func elements(intersecting worldRect: CGRect) -> [CanvasElementID] { [] }
    var contentBounds: CGRect { .null }
    func perform(_ command: CanvasSceneCommand) {}

    var selection: Set<CanvasElementID> = []
    var overlay = CanvasOverlay()
    var undoManager: UndoManager? { nil }
    func requestRedraw() {}
    func setCursor(_ cursor: CanvasCursor) {}
}
