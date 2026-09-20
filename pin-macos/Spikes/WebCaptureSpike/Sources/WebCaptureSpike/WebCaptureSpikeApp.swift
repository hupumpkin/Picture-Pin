import AppKit
import SwiftUI

@main
struct WebCaptureSpikeApp: App {
    @NSApplicationDelegateAdaptor(SpikeAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Web Capture Spike") {
            WebWorkspaceView()
        }
        .defaultSize(width: 1_180, height: 760)
    }
}

/// `swift run` 跑出来的是裸可执行文件，没有 .app 包，AppKit 不会自动把它提升为
/// 前台应用；这里显式声明 regular 并抢一次焦点，否则窗口起在终端后面。
@MainActor
final class SpikeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        if CommandLine.arguments.contains("--self-check") {
            let online = CommandLine.arguments.contains("--online")
            NSApp.setActivationPolicy(.accessory)
            Task {
                let code = await SelfCheck.run(online: online)
                SelfCheck.cleanup()
                exit(code)
            }
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

    /// 退出时清掉临时夹具，满足「退出后临时文件已清理」的人工检查项。
    nonisolated func applicationWillTerminate(_: Notification) {
        LocalFixturePage.cleanupSharedDirectory()
    }
}
