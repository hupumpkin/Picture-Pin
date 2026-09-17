import AppKit
import CoreGraphics
import Foundation
import SwiftUI

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
        await staleDecodeIsCancelled()
        performanceProbeIsOffByDefault()
        floatingLayerSitsAboveCanvas()
        canvasDoesNotDrawOutsideItsBounds()
        feelConfigurationIsWired()
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
            commands: CanvasCommandRelay(),
            onSceneChange: onSceneChange,
            onSelectionChange: onSelectionChange,
            onCameraChange: { _ in }
        )
        let view = CanvasHostNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
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

        // 批次 A 的占位提供者**启动即 `.loaded([])`**。
        // 若改成 `.idle` 而 `refresh()` 又什么都不做，面板会永远停在转圈——
        // 那看起来像卡死，不像空。
        for source in catalog {
            expect(source.provider.content == .loaded([]),
                   "\(source.id.raw) 的占位提供者启动即空列表")
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

        let coarser = coordinator.renderedTier(of: id)
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
        let started = await waitUntil("粗档请求已发出") { coordinator.renderedTier(of: id) == coarse }
        expect(started, "挂载时先按粗档请求",
               detail: "\(String(describing: coordinator.renderedTier(of: id)))")
        expect(coordinator.renderedImageSize(of: id) == nil,
               "粗档还没回来（就是它要迟到）")

        var zoomed = coordinator.camera
        zoomed.zoom = 4
        coordinator.applyExternalCamera(zoomed)

        let fine = coordinator.renderedTier(of: id)
        expect(fine == .full, "放大后要原分辨率档", detail: "\(String(describing: fine))")
        let fineSize = fine?.pixelSize(forOriginal: asset.pixelSize)
        _ = await waitUntil("细档先到") { coordinator.renderedImageSize(of: id) == fineSize }

        // 等到超过粗档的延迟：它一定已经回来了。回来了但**不该生效**。
        try? await Task.sleep(nanoseconds: 900_000_000)
        expect(coordinator.renderedImageSize(of: id) == fineSize,
               "迟到的粗档结果被丢弃，没有把画面换回糊的",
               detail: "期望 \(String(describing: fineSize))，得到 \(String(describing: coordinator.renderedImageSize(of: id)))")
    }

    /// 只数请求次数，别的原样转发。
    ///
    /// "渲染器会不会每帧重复发请求"读代码看不出来——它取决于几个 guard 的组合，
    /// 而那正是最容易在某次改动里被顺手删掉的东西。
    @MainActor
    private final class CountingImageProvider: ImageProvider {
        private let wrapped: any ImageProvider
        private(set) var requestCount = 0

        init(_ wrapped: any ImageProvider) { self.wrapped = wrapped }

        func metadata(for asset: AssetID) async -> ImageMetadata? {
            await wrapped.metadata(for: asset)
        }

        func image(for asset: AssetID, targetPixelSize: CGSize) async -> ImageRequestResult {
            requestCount += 1
            return await wrapped.image(for: asset, targetPixelSize: targetPixelSize)
        }
    }

    /// 把某一档的解码拖慢。除了拖延，其余行为与内层完全一致——**缓存也共用**，
    /// 所以被拖慢的只有时间，不是内容。
    @MainActor
    private final class DelayedTierProvider: ImageProvider {
        private let wrapped: SyntheticImageProvider
        private let slowLevel: Int
        private let delay: TimeInterval

        init(wrapping wrapped: SyntheticImageProvider, slowLevel: Int, delay: TimeInterval) {
            self.wrapped = wrapped
            self.slowLevel = slowLevel
            self.delay = delay
        }

        func metadata(for asset: AssetID) async -> ImageMetadata? {
            await wrapped.metadata(for: asset)
        }

        func image(for asset: AssetID, targetPixelSize: CGSize) async -> ImageRequestResult {
            if let metadata = await wrapped.metadata(for: asset),
               LODTier.fitting(targetPixelSize, original: metadata.pixelSize).level == slowLevel {
                // 拖延放在委托**之前**：无论内层是解码还是命中缓存，迟到都会发生。
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            return await wrapped.image(for: asset, targetPixelSize: targetPixelSize)
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
            coordinator.renderedTier(of: id) == LODTier(level: 2)
        }
        expect(requested, "挂载时请求的是「刚好覆盖需求」的那一档",
               detail: "渲染器记的档位 \(String(describing: coordinator.renderedTier(of: id)?.level))")

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
            second.renderedTier(of: id) == LODTier(level: 2)
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

    // MARK: - 性能埋点

    /// 性能探针**默认关着**。
    ///
    /// 这条断言放在整个自检的**最后**，因为它读的是"跑完前面所有断言之后探针里
    /// 有什么"。上面 370 多条断言把渲染、缩放、缓存、取消的路径全走了一遍——
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
            guard let extent = toolbarExtent(in: runs) else {
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

    /// 工具条实际占到的横向范围：命中段里最靠左的那一簇。
    ///
    /// 两处细节都不能省：
    ///
    /// - **先滤掉窄段**。面板的调宽把手（8pt 宽）也落在这条扫描线上，它不是
    ///   工具条的一部分；工具条的按钮是 26pt。第一版没滤，取到的"工具条"
    ///   是 322..330 那个把手，断言报出「工具条中点 326」这种一眼假的数。
    /// - **整簇取首尾**，不能只取第一段：按钮之间有留白，段与段是分开的。
    ///   间隔小于 20pt 的算同一条工具条。
    private static func toolbarExtent(in runs: [(CGFloat, CGFloat)]) -> (CGFloat, CGFloat)? {
        let buttons = runs.filter { $0.1 - $0.0 >= 20 }
        guard let first = buttons.first else { return nil }
        var maxX = first.1
        for run in buttons.dropFirst() where run.0 - maxX < 20 { maxX = run.1 }
        return (first.0, maxX)
    }

    /// 在视图树里找画布视图。命中测试返回的就是它，所以要按类型找。
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
    /// 这里**不经过协调器**，直接给 `MinimalInputAdapter` 一个只会计数的
    /// `CanvasContext`。走的是和真实宿主相同的代码路径（适配器只认协议），
    /// 但"推了几帧"变成了直接读一个计数器，而不是从相机位置反推。
    private static func framesEmitted(frameInterval: TimeInterval, window: TimeInterval) async -> Int {
        var configuration = MotionConfiguration.default
        configuration.programmaticCameraDuration = 0.1
        configuration.feel.animationFrameInterval = frameInterval
        let context = FrameCountingContext(configuration: configuration)
        let adapter = MinimalInputAdapter()
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
}
