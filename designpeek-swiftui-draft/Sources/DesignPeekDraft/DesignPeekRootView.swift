import SwiftUI

struct DesignPeekRootView: View {
    @State private var mode: WorkspaceMode = .library
    @State private var librarySelection: LibraryFilter? = .inbox
    @State private var selectedCaptures = Set<MockCapture.ID>()
    @State private var searchText = ""
    @State private var thumbnailSize = 154.0

    var body: some View {
        NavigationSplitView {
            DesignPeekSidebar(mode: $mode, librarySelection: $librarySelection)
                .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 270)
        } detail: {
            Group {
                switch mode {
                case .library:
                    CaptureLibraryView(
                        selection: librarySelection ?? .inbox,
                        selectedCaptures: $selectedCaptures,
                        searchText: $searchText,
                        thumbnailSize: $thumbnailSize
                    )
                case .analysis:
                    AnalysisWorkspaceView()
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Color(red: 0.18, green: 0.39, blue: 0.85))
    }
}
