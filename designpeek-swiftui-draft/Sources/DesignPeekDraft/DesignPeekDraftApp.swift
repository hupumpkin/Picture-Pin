import SwiftUI

@main
struct DesignPeekDraftApp: App {
    var body: some Scene {
        WindowGroup {
            DesignPeekRootView()
                .frame(minWidth: 1040, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1320, height: 840)
    }
}
