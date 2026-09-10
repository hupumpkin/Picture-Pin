import SwiftUI

struct CaptureLibraryView: View {
    let selection: LibraryFilter
    @Binding var selectedCaptures: Set<MockCapture.ID>
    @Binding var searchText: String
    @Binding var thumbnailSize: Double

    private var title: String {
        switch selection {
        case .inbox: return "新添加截图"
        case .favorites: return "已收藏"
        case .folder(let name): return name
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize + 30), spacing: 18, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                ForEach(filteredCaptures) { capture in
                    CaptureCard(
                        capture: capture,
                        isSelected: selectedCaptures.contains(capture.id)
                    )
                    .onTapGesture {
                        if selectedCaptures.contains(capture.id) {
                            selectedCaptures.remove(capture.id)
                        } else {
                            selectedCaptures.insert(capture.id)
                        }
                    }
                    .contextMenu {
                        Button("查看大图", systemImage: "arrow.up.left.and.arrow.down.right") { }
                        Button("收藏", systemImage: "star") { }
                        Button("在 Finder 中显示", systemImage: "folder") { }
                        Divider()
                        Button("删除截图", systemImage: "trash", role: .destructive) { }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle(title)
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索截图文字、备注或文件夹")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !selectedCaptures.isEmpty {
                    Text("已选 \(selectedCaptures.count) 张")
                        .foregroundStyle(.secondary)
                    Button("加入素材文件夹", systemImage: "folder.badge.plus") { }
                    Button("加入分析项目", systemImage: "sparkles.rectangle.stack") { }
                }
                Button("批量管理", systemImage: "checkmark.circle") { }
            }

            ToolbarItem(placement: .status) {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.grid.3x2")
                    Slider(value: $thumbnailSize, in: 128...210)
                        .frame(width: 92)
                }
            }
        }
    }

    private var filteredCaptures: [MockCapture] {
        guard !searchText.isEmpty else { return PreviewData.captures }
        return PreviewData.captures.filter { $0.app.localizedCaseInsensitiveContains(searchText) }
    }
}

private struct CaptureCard: View {
    let capture: MockCapture
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            MockScreenshotView(capture: capture)
                .aspectRatio(0.54, contentMode: .fit)

            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(capture.palette.accent)
                    .frame(width: 18, height: 18)
                    .overlay {
                        Text(String(capture.app.prefix(1)))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(capture.palette == .paper ? .white : .black)
                    }
                Text(capture.app)
                    .font(.caption)
                Spacer()
                Text(capture.time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(9)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 0.5)
        }
        .overlay(alignment: .topTrailing) {
            if isSelected || hovering {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary, isSelected ? Color.accentColor : Color.white.opacity(0.9))
                    .padding(8)
            }
        }
        .shadow(color: .black.opacity(hovering ? 0.11 : 0.035), radius: hovering ? 12 : 3, y: hovering ? 5 : 1)
        .scaleEffect(hovering ? 1.01 : 1)
        .animation(.easeOut(duration: 0.16), value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct MockScreenshotView: View {
    let capture: MockCapture

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            VStack(spacing: 0) {
                HStack {
                    Text(capture.time)
                    Spacer()
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100percent")
                }
                .font(.system(size: max(6, width * 0.045), weight: .medium))
                .padding(.horizontal, width * 0.07)
                .frame(height: width * 0.14)

                VStack(alignment: .leading, spacing: width * 0.07) {
                    Text(headline)
                        .font(.system(size: width * 0.11, weight: .bold))
                        .lineLimit(2)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(capture.palette.accent)
                        .frame(width: width * 0.52, height: width * 0.05)

                    ForEach(0..<4, id: \.self) { index in
                        HStack(spacing: width * 0.05) {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(index.isMultiple(of: 2) ? capture.palette.accent.opacity(0.95) : capture.palette.foreground.opacity(0.18))
                                .frame(width: width * 0.27, height: width * 0.31)
                            VStack(alignment: .leading, spacing: width * 0.035) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(capture.palette.foreground.opacity(0.84))
                                    .frame(height: width * 0.045)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(capture.palette.foreground.opacity(0.35))
                                    .frame(width: width * 0.46, height: width * 0.035)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(capture.palette.foreground.opacity(0.22))
                                    .frame(width: width * 0.36, height: width * 0.035)
                            }
                        }
                    }
                }
                .padding(width * 0.08)
                Spacer(minLength: 0)
            }
            .foregroundStyle(capture.palette.foreground)
            .background(capture.palette.background)
        }
    }

    private var headline: String {
        ["深色会员页", "成长体系", "新品首发", "采集成就", "品质生活", "签到有礼"][capture.variant % 6]
    }
}
