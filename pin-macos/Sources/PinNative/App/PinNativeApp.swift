import SwiftUI

/// 进程入口。
///
/// 不用 `@main` 直接标在 `App` 上，是因为需要先看一眼命令行参数：带 `--snapshot`
/// 时跑离屏截图然后退出，不创建任何窗口（`Tools/SnapshotHarness.swift`）。
/// 截图路径必须静默——它会随每次改动跑，不应该在屏幕上闪窗口，也不应该抢焦点。
@main
enum PinNativeEntry {
    /// 从批次 B 起 `main` 是 **async** 的，因为自检里出现了真正异步的被测对象
    /// （图片提供者要 `await` 一次解码）。
    ///
    /// 不这么做的话只剩两条路，两条都更差：
    ///
    /// - **在同步的 `main` 里抽干 RunLoop 等 Task 完成**：主 actor 被那个同步函数
    ///   占着，能不能推进全看 RunLoop 顺不顺带把主队列跑了。真出问题时的表现是
    ///   **挂住**而不是**失败**——自检挂住比自检报错难查得多。
    /// - **把断言写成"发起请求"就结束**：那就等于不验。异步管线恰恰是"看代码没问题、
    ///   跑起来是另一回事"的高发区。
    static func main() async {
        // 这两条路径都在 `PinNativeApp` 之前退出，所以它们不需要一个可用的
        // 数据 profile——否则 profile 解析本身就没法在自检里验证。
        if SelfTest.isRequested {
            await SelfTest.runAndExit()
        }
        if SnapshotHarness.isRequested {
            await SnapshotHarness.runAndExit()
        }
        // B2 的实测报告（路线图 §2.4）。和上面两条一样在 `PinNativeApp` 之前退出：
        // 它不需要窗口，也不该在屏幕上闪一个窗口再量"每帧主线程工作"。
        if PerformanceReport.isRequested {
            await PerformanceReport.runAndExit()
        }
        // `App.main()` 是非隔离的同步入口，它自己会跑 runloop，所以这里不 await。
        PinNativeApp.main()
    }
}

struct PinNativeApp: App {
    private let environment: AppEnvironment
    @State private var model: WorkspaceModel

    init() {
        // 未知 profile 在这里就退出（`resolveForLaunch` 里报错 + 非零退出），
        // 不会带着一个猜出来的数据目录继续跑。
        let environment = AppEnvironment.resolveForLaunch()
        self.environment = environment
        _model = State(initialValue: WorkspaceModel(environment: environment))
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceView(model: model)
                .task {
                    // 路线图 §6：全新空库。这里只建目录结构，不读任何旧数据。
                    // 失败会显示在界面上——`try?` 会让它表现成「界面正常、数据不落盘」。
                    model.prepareStorage()
                    // 系统报内存压力时按级别收缩图片缓存（路线图 §2.3）。
                    // 迟一点装没有关系：它挡的是"系统已经在换页"，不是首帧。
                    MemoryPressureMonitor.shared.start(handler: { [imageCache = model.imageCache] level in
                        imageCache.handle(level)
                    })
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("放大") { model.commands.zoomStep?(model.motionConfiguration.feel.zoomStepFactor) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("缩小") { model.commands.zoomStep?(1 / model.motionConfiguration.feel.zoomStepFactor) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("实际大小") { model.commands.zoomTo?(1) }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Button("定位到全部内容") { model.commands.focusContent?() }
                    .keyboardShortcut("1", modifiers: [.command, .shift])
                    .disabled(model.scene.elements.isEmpty)
            }
            // 开发构建专用（`Tools/DevelopmentCommands.swift`）。产品默认是空白画布，
            // 所以"图片显示得对不对"必须有一个人工入口才看得到。
            #if DEBUG
            CommandMenu("开发") {
                Button("插入演示素材") { DevelopmentCommands.insertDemoBatch(into: model) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("新建画布并放入素材") { DevelopmentCommands.seedNewBoard(in: model) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Text("切换到第 \(model.boards.activeIndexDisplay + 1) / \(model.boards.boards.count) 块画布")
                    .disabled(true)
            }
            #endif
        }
    }
}
