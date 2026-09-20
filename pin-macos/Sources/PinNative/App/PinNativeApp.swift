import AppKit
import SwiftUI

@MainActor
final class PinApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: WorkspaceModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { @MainActor in
            let failure = await model.flushLibrary()
            sender.reply(toApplicationShouldTerminate: failure == nil)
        }
        return .terminateLater
    }
}

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
        // §3.7 调试入口。同样不开窗口：一个无 UI 导入（供快照与人工验收），
        // 一个打印素材库与库文件状态（供送审）。默认打真实 profile，
        // 自动化流程用 `--data-dir` 打临时目录。
        if HeadlessImport.isRequested {
            await HeadlessImport.runAndExit()
        }
        if LibraryReport.isRequested {
            await LibraryReport.runAndExit()
        }
        // `App.main()` 是非隔离的同步入口，它自己会跑 runloop，所以这里不 await。
        PinNativeApp.main()
    }
}

struct PinNativeApp: App {
    @NSApplicationDelegateAdaptor(PinApplicationDelegate.self) private var appDelegate
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
                    appDelegate.model = model
                    // 路线图 §6：全新空库。这里建目录结构并打开库（打不开会显示
                    // 在界面上——`try?` 会让它表现成「界面正常、数据不落盘」）。
                    // 「暂时打不开」（忙锁、临时 I/O）会自动再试几次；
                    // 库真的坏了则走隔离，两件事的文案在界面上是分开的。
                    await model.recoverStorage()
                    // 系统报内存压力时按级别收缩图片缓存（路线图 §2.3）。
                    // 迟一点装没有关系：它挡的是"系统已经在换页"，不是首帧。
                    MemoryPressureMonitor.shared.start(handler: { [imageCache = model.imageCache] level in
                        imageCache.handle(level)
                    })
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            // 撤销 / 重做 / 全选。
            //
            // 三项都用 `target: nil` + `Selector` 挂到响应链上，而不是写字面闭包：
            // 撤销栈是**窗口的** `UndoManager`，只有第一响应者（画布视图）知道
            // 该撤销哪一份；写成闭包就得让 `WorkspaceModel` 也持一个撤销栈，
            // 于是同一个窗口里有两套撤销历史。
            //
            // **选择的必须是带冒号的 `undo:` / `redo:`。**
            //
            // 这里原先写的是 `#selector(UndoManager.undo)`——那是 `UndoManager`
            // 自己的无参方法，而 `UndoManager` **不在响应链上**。实测（`NSView` /
            // `NSWindow` / `NSApplication` 各问一遍 `responds(to:)`）：三者都不响应
            // 无冒号的 `undo`，于是菜单发出去的那一下落到空处，撤销点不动、
            // 快捷键也没反应，而画布上那条路一直是对的——只是没人走到它。
            //
            // 带冒号的 `undo:` 才是 AppKit 的标准动作，也是画布实现的那个
            // （`CanvasHostNSView` 的 `@objc func undo(_:)`）：画布在响应链上就由
            // 画布接住，不在时 `NSWindow` 会兜底转发给它自己的撤销栈——两条路
            // 用的是同一个窗口 `UndoManager`，所以两头都对。
            //
            // 可用状态由 `CanvasHostNSView.validateMenuItem` 决定（画布没挂载、
            // 栈是空的时候自动变灰）。
            // 选择器从 `CanvasResponderAction` 取，**不在这里重写一遍**：
            // 菜单和画布之间唯一的接头就是它，两处各写一份的话，写歪一个字符
            // 就落到空处，而且两边都还在、编译也过、没有任何报错。
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { NSApp.sendAction(CanvasResponderAction.undo, to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: .command)
                Button("重做") { NSApp.sendAction(CanvasResponderAction.redo, to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .pasteboard) {
                // 粘贴用**标准选择器** `paste:`：搜索框里的 ⌘V 仍然要粘文字，
                // 而文本视图在响应链上更靠前，会先接住。写成自定义选择器或
                // 直接挂闭包，菜单会在响应链之前把 ⌘V 抢走。
                Button("粘贴") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                    .keyboardShortcut("v", modifiers: .command)
                Divider()
                Button("全选") { NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil) }
                    .keyboardShortcut("a", modifiers: .command)
            }
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
                Button("插入演示素材") {
                    Task { await DevelopmentCommands.insertDemoBatch(into: model) }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("新建画布并放入素材") {
                    Task { await DevelopmentCommands.seedNewBoard(in: model) }
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Text("切换到第 \(model.boards.activeIndexDisplay + 1) / \(model.boards.boards.count) 块画布")
                    .disabled(true)
            }
            #endif
        }
    }
}
