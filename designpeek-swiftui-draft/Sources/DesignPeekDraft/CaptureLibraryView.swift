import SwiftUI

struct CaptureLibraryView: View {
    let selection: LibraryFilter
    @Binding var selectedCaptures: Set<MockCapture.ID>
    @Binding var searchText: String
    @Binding var thumbnailSize: Double
    @State private var previewCapture: MockCapture?

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
        ZStack(alignment: .bottom) {
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
                            Button("查看大图", systemImage: "arrow.up.left.and.arrow.down.right") {
                                previewCapture = capture
                            }
                            Button("收藏", systemImage: "star") { }
                            Button("在 Finder 中显示", systemImage: "folder") { }
                            Divider()
                            Button("删除截图", systemImage: "trash", role: .destructive) { }
                        }
                    }
                }
                .padding(24)
                .padding(.bottom, 72)
            }

            LibraryGlassDock(
                selectedCount: selectedCaptures.count,
                thumbnailSize: $thumbnailSize,
                onPreview: {
                    previewCapture = PreviewData.captures.first {
                        selectedCaptures.contains($0.id)
                    }
                },
                onClear: { selectedCaptures.removeAll() }
            )
            .padding(.bottom, 18)
        }
        .navigationTitle(title)
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索截图文字、备注或文件夹")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("导入截图", systemImage: "square.and.arrow.down") { }
                Button("批量管理", systemImage: "checkmark.circle") { }
            }
        }
        .sheet(item: $previewCapture) { capture in
            CapturePreview(capture: capture)
                .frame(minWidth: 760, minHeight: 620)
                .presentationBackground(.clear)
        }
    }

    private var filteredCaptures: [MockCapture] {
        guard !searchText.isEmpty else { return PreviewData.captures }
        return PreviewData.captures.filter { $0.app.localizedCaseInsensitiveContains(searchText) }
    }
}

private struct LibraryGlassDock: View {
    let selectedCount: Int
    @Binding var thumbnailSize: Double
    let onPreview: () -> Void
    let onClear: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 12) {
                if selectedCount == 0 {
                    Label("调整缩略图", systemImage: "rectangle.grid.3x2")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .help("调整缩略图大小")

                    Slider(value: $thumbnailSize, in: 128...210)
                        .frame(width: 112)

                    Divider()
                        .frame(height: 18)

                    Button("排序", systemImage: "arrow.up.arrow.down") { }
                        .labelStyle(.iconOnly)
                        .help("排序")
                    Button("筛选", systemImage: "line.3.horizontal.decrease") { }
                        .labelStyle(.iconOnly)
                        .help("筛选")
                } else {
                    Text("已选 \(selectedCount) 张")
                        .font(.callout.weight(.medium))

                    Divider()
                        .frame(height: 18)

                    if selectedCount == 1 {
                        Button("查看大图", systemImage: "arrow.up.left.and.arrow.down.right", action: onPreview)
                            .labelStyle(.iconOnly)
                            .help("查看大图")
                    }

                    Button("加入素材文件夹", systemImage: "folder.badge.plus") { }
                        .labelStyle(.iconOnly)
                        .help("加入素材文件夹")
                    Button("加入分析项目", systemImage: "sparkles.rectangle.stack") { }
                        .labelStyle(.iconOnly)
                        .help("加入分析项目")
                    Button("取消选择", systemImage: "xmark", action: onClear)
                        .labelStyle(.iconOnly)
                        .help("取消选择")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        }
    }
}

private struct CapturePreview: View {
    let capture: MockCapture
    @Environment(\.dismiss) private var dismiss
    @State private var zoom = 1.0
    @State private var rotation = 0.0
    @State private var isFavorite = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()

            MockScreenshotView(capture: capture)
                .aspectRatio(0.54, contentMode: .fit)
                .frame(maxWidth: 390, maxHeight: 500)
                .scaleEffect(zoom)
                .rotationEffect(.degrees(rotation))
                .shadow(color: .black.opacity(0.42), radius: 32, y: 14)
                .animation(.smooth(duration: 0.24), value: zoom)
                .animation(.smooth(duration: 0.24), value: rotation)

            VStack {
                HStack {
                    Spacer()
                    Button("关闭", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .help("关闭")
                }
                .padding(20)

                Spacer()

                previewDock
                    .padding(.bottom, 22)
            }
        }
    }

    private var previewDock: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 12) {
                toolButton("缩小", systemImage: "minus.magnifyingglass") {
                    zoom = max(0.6, zoom - 0.2)
                }

                Text("\(Int(zoom * 100))%")
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .frame(width: 44)

                toolButton("放大", systemImage: "plus.magnifyingglass") {
                    zoom = min(1.8, zoom + 0.2)
                }
                toolButton("适合窗口", systemImage: "arrow.down.right.and.arrow.up.left") {
                    zoom = 1
                }

                Divider()
                    .frame(height: 20)

                toolButton("向左旋转", systemImage: "rotate.left") {
                    rotation -= 90
                }
                toolButton(isFavorite ? "取消收藏" : "收藏", systemImage: isFavorite ? "star.fill" : "star") {
                    isFavorite.toggle()
                }
                toolButton("取色", systemImage: "eyedropper") { }
                toolButton("分享", systemImage: "square.and.arrow.up") { }
                toolButton("图片信息", systemImage: "info.circle") { }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        }
    }

    private func toolButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .font(.system(size: 15, weight: .medium))
            .help(title)
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
