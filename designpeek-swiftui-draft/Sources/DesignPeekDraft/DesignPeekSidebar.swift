import SwiftUI

struct DesignPeekSidebar: View {
    @Binding var mode: WorkspaceMode
    @Binding var librarySelection: LibraryFilter?

    var body: some View {
        VStack(spacing: 0) {
            brandHeader

            Picker("工作区", selection: $mode) {
                ForEach(WorkspaceMode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.bottom, 14)

            Divider()

            if mode == .library {
                librarySidebar
            } else {
                analysisSidebar
            }

            Divider()
            sidebarFooter
        }
        .background(.ultraThinMaterial)
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary)
                    .frame(width: 30, height: 30)
                Image(systemName: "viewfinder")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("DesignPeek")
                    .font(.headline)
                Text("设计透视")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }

    private var librarySidebar: some View {
        List(selection: $librarySelection) {
            Section {
                Label("新添加截图", systemImage: "tray.full")
                    .badge(19)
                    .tag(LibraryFilter.inbox)
                Label("已收藏", systemImage: "star")
                    .badge(1)
                    .tag(LibraryFilter.favorites)
            }

            Section {
                ForEach(PreviewData.materialFolders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .badge(folder.count)
                        .tag(LibraryFilter.folder(folder.name))
                }
            } header: {
                HStack {
                    Text("素材文件夹")
                    Spacer()
                    Button("新建文件夹", systemImage: "plus") { }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }

            Section("竞品 App") {
                DisclosureGroup("按来源查看") {
                    Label("小红书", systemImage: "app.badge")
                    Label("淘宝", systemImage: "app.badge")
                    Label("京东", systemImage: "app.badge")
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var analysisSidebar: some View {
        List {
            Section("待归类分析") {
                ForEach(PreviewData.analyses) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.image")
                            .foregroundStyle(.secondary)
                        Text(item.title)
                            .lineLimit(1)
                        Spacer()
                        Circle()
                            .fill(item.completed ? Color.blue : Color.secondary.opacity(0.45))
                            .frame(width: 6, height: 6)
                    }
                }
            }

            Section {
                ForEach(PreviewData.analysisFolders) { folder in
                    DisclosureGroup {
                        Text("拖动分析到这里")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } label: {
                        Label(folder.name, systemImage: "folder")
                            .badge(folder.count)
                    }
                }
            } header: {
                HStack {
                    Text("文件夹")
                    Spacer()
                    Button("新建文件夹", systemImage: "plus") { }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 8) {
            Button("边逛边截", systemImage: "dot.viewfinder") { }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)

            HStack {
                Button("本地上传", systemImage: "square.and.arrow.down") { }
                Button("AI 设置", systemImage: "sparkles") { }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(12)
    }
}
