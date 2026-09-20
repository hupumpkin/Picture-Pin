import AppKit
import SwiftUI

/// 离屏截图：把界面按指定尺寸渲染成 PNG，不创建可见窗口。
///
/// ## 为什么需要它
///
/// 画布这类界面「编译通过」几乎不说明任何问题——坐标系搞反、网格间距算错、
/// 面板宽度吃掉了画布，全都能编译。要发现这些只能看。但每次改动都让人工开窗口
/// 看一眼不现实，用系统截图又会把用户桌面拍进去。
///
/// 这里走 `NSHostingView` + `cacheDisplay`：离屏窗口不 order front，不抢焦点，
/// 不需要屏幕录制权限，渲染结果与真实窗口走同一套布局与绘制路径。
/// 与 `CanvasHostView` 里那套 CALayer 渲染也因此是同一份代码，不存在
/// 「测的和跑的不是一个东西」。
///
/// 只在 Debug 语义下使用（由 `--snapshot` 参数触发），不进正式交互路径。
@MainActor
enum SnapshotHarness {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--snapshot")
    }

    /// 路线图约定的验证尺寸。三档覆盖：小窗口（面板会挤压画布）、
    /// 默认尺寸、大窗口。
    static let sizes: [CGSize] = [
        CGSize(width: 1024, height: 700),
        CGSize(width: 1280, height: 800),
        CGSize(width: 1440, height: 900),
    ]

    static func runAndExit() async -> Never {
        let outputDirectory = resolveOutputDirectory()
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            FileHandle.standardError.write(Data("无法创建输出目录：\(error)\n".utf8))
            exit(1)
        }

        // NSApplication 必须在任何 AppKit 绘制之前存在，否则颜色解析与图层
        // 建立会在某些系统版本上静默失败。`.accessory` 保证不出现 Dock 图标。
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        var written: [String] = []
        for size in sizes {
            for appearance in Appearance.allCases {
                let name = "workspace-\(Int(size.width))x\(Int(size.height))-\(appearance.suffix).png"
                let url = outputDirectory.appendingPathComponent(name)
                if let data = await render(size: size, appearance: appearance) {
                    try? data.write(to: url)
                    written.append(name)
                } else {
                    FileHandle.standardError.write(Data("渲染失败：\(name)\n".utf8))
                }
            }
        }

        // 再截一张**有内容**的：默认快照截的是空画布（那是产品真实的启动状态，
        // 必须继续截），但空画布证明不了图片管线是通的。这张把合成素材放进画布，
        // 是"图片真的显示了、而且比例没被拉伸"的视觉证据。
        //
        // 只截一张浅色 1280×800，是因为它要回答的问题不随尺寸和明暗变化；
        // 铺满六张只会让每次改动都多出四张要看。
        //
        // ## 为什么这张只在 debug 构建里有
        //
        // 它要往画布上放东西，而唯一的入口是 `DevelopmentCommands`——那份代码
        // 整个包在 `#if DEBUG` 里（正式构建不携带演示内容）。所以 release 构建
        // 只能截出 6 张空画布。这不是"少一张图"的问题：**「图片管线是通的」
        // 这条证据只在 debug 构建里存在**，release 的那 6 张不能当作它成立。
        // 下面那行 stderr 是给"为什么少一张"一个当场可见的解释，而不是让人去猜。
        #if DEBUG
        let contentSize = CGSize(width: 1280, height: 800)
        let contentName = "workspace-content-\(Int(contentSize.width))x\(Int(contentSize.height))-light.png"
        if let data = await render(size: contentSize, appearance: .light, withContent: true) {
            try? data.write(to: outputDirectory.appendingPathComponent(contentName))
            written.append(contentName)
        } else {
            FileHandle.standardError.write(Data("渲染失败：\(contentName)\n".utf8))
        }

        // 同一批内容，**不套相机**（缩放 100%）再截一张。
        //
        // 它存在的唯一理由是那半个条件：内容比视口宽时，超出去的元素会不会画到
        // 左侧素材面板上。上面那张套了相机，内容一定装得下，**永远看不见这个**。
        // 这一张是用户实测发现越界之后补的——之前"图片显示正常"的截图其实
        // 每天都在掩盖同一个 bug。
        let overflowName = "workspace-overflow-\(Int(contentSize.width))x\(Int(contentSize.height))-light.png"
        if let data = await render(size: contentSize, appearance: .light,
                             withContent: true, fittingContent: false) {
            try? data.write(to: outputDirectory.appendingPathComponent(overflowName))
            written.append(overflowName)
        } else {
            FileHandle.standardError.write(Data("渲染失败：\(overflowName)\n".utf8))
        }
        #else
        FileHandle.standardError.write(Data(
            "release 构建跳过内容快照：演示素材只在 debug 构建里（DevelopmentCommands）。\n".utf8
        ))
        #endif

        let summary = "已生成 \(written.count) 张：\n" + written.map { "  " + $0 }.joined(separator: "\n")
        print(summary)
        print("输出目录：\(outputDirectory.path)")
        exit(0)
    }

    enum Appearance: String, CaseIterable {
        case light
        case dark

        var suffix: String { rawValue }

        var nsAppearance: NSAppearance? {
            NSAppearance(named: self == .dark ? .darkAqua : .aqua)
        }
    }

    /// 渲染一张。倍率固定 2x——与 Retina 上的真实表现一致，1x 会掩盖
    /// 半像素对齐问题（网格线的 0.5 偏移就是为 2x 准备的）。
    /// - Parameter fittingContent: 有内容时是否把相机套到内容上。
    ///   `true` 用于"看清每一张图的比例"，`false` 用于复现"内容比视口宽"这个条件
    ///   ——越界只在后者发生，套上相机就永远看不见它。
    static func render(
        size: CGSize,
        appearance: Appearance,
        withContent: Bool = false,
        fittingContent: Bool = true
    ) async -> Data? {
        // 快照要画出真像素，就得有真库（C1 起画布像素来自素材库）。在**临时
        // 目录**里开一份：快照工具绝不能往任何 profile 的真实数据目录里写
        // 演示素材——那会让"截一张图"变成"污染一次开发数据"。
        guard let scratch = makeScratchDataDirectory() else { return nil }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = WorkspaceModel(
            environment: AppEnvironment(profile: .cc, dataDirectory: scratch)
        )
        await model.recoverStorage()
        guard model.storageError == nil else { return nil }
        #if DEBUG
        if withContent {
            await DevelopmentCommands.insertDemoBatch(into: model)
            await DevelopmentCommands.insertDemoBatch(into: model)
        }
        if withContent, fittingContent {
            // 把相机套到内容上。不这么做的话这批素材比视口宽，截图只能看到
            // 中间一块，"比例对不对"反而看不全——而比例正是这张截图要证明的事。
            // 顺带走了一遍"定位到全部内容"实际调用的那段换算。
            var camera = model.camera
            camera.fit(worldRect: model.scene.contentBounds)
            model.camera = camera
        }
        #else
        // 正式构建里 `withContent` 只能是 false：唯一会传 true 的调用点本身
        // 就在 `#if DEBUG` 里，而演示内容（`DevelopmentCommands`）不存在。
        // 保留这个参数是为了让两个构建里的签名一致——签名分叉会让调用点也得
        // 跟着分叉，那才是真正的麻烦。
        #endif
        let root = WorkspaceView(model: model)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(origin: .zero, size: size)

        // 不 order front：窗口存在即可满足 AppKit 的布局前提，但它不可见，
        // 也不会成为 key window。
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance.nsAppearance
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        // SwiftUI 的首轮布局有一部分是异步的（尤其是 scroll/glass 这类需要
        // 尺寸的容器），解码也是异步的（真提供者 §3.2）。睡一小段让它们落定，
        // 否则截到的是中间态——主 actor 挂起期间主 runloop 照常转，
        // 布局与解码任务的回调都能排上队。
        try? await Task.sleep(for: .seconds(0.35))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        // rep.size 设成点尺寸，这张位图就成了 2x 表示，
        // cacheDisplay 会按这个倍率绘制。
        rep.size = size
        hostingView.cacheDisplay(in: CGRect(origin: .zero, size: size), to: rep)

        return rep.representation(using: .png, properties: [:])
    }

    /// 渲染用的临时数据目录（快照的"库"开在这里，用完即删）。
    private static func makeScratchDataDirectory() -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pin-snapshot-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return nil
        }
    }

    /// 输出目录默认在工程内的 `build/snapshots/`，可用 `--snapshot-dir` 覆盖。
    private static func resolveOutputDirectory() -> URL {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot-dir"),
           index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1])
        }
        // 从可执行文件位置向上找含 Package.swift 的目录。
        // 不数层级：`.build/debug/` 与 `.build/arm64-apple-macosx/debug/` 两种
        // 布局的深度不同，数层级会在 `swift run` 和直接执行二进制时给出不同答案
        // （第一次跑就踩到了，输出跑到了 `.build/build/snapshots`）。
        var directory = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path
            ) {
                return directory.appendingPathComponent("build/snapshots", isDirectory: true)
            }
            directory = directory.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/snapshots", isDirectory: true)
    }
}
