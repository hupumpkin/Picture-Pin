import AppKit
import SwiftUI

@MainActor
final class WebWorkspaceModel: ObservableObject {
    @Published var address = "https://huaban.com/"
    @Published var result: CaptureResult?
    @Published var status = "准备就绪"
    @Published var lastTypes: [String] = []

    let browser = WebViewController()
    let receiver = CaptureReceiver()
    let log = CaptureLog()
    let fixture: LocalFixturePage

    init() {
        fixture = LocalFixturePage()
    }

    func openAddress() {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            status = "请输入 http 或 https 地址"
            return
        }
        browser.load(url)
    }

    func openFixture() {
        browser.loadFixture(fixture.indexURL, allowingReadAccessTo: fixture.directory)
        address = fixture.indexURL.absoluteString
    }

    func captureClipboard() {
        let snapshot = receiver.snapshot(of: .general)
        consume(snapshot: snapshot, isDrag: false)
    }

    func captureDrop(_ snapshot: CapturePasteboardSnapshot) {
        consume(snapshot: snapshot, isDrag: true)
    }

    /// 拖拽进了接收区却没有宣告任何类型：记一条，用来区分是 WebKit 还是接收侧的问题。
    func captureRejectedDrop(types: [String]) {
        lastTypes = types
        let failure = CaptureFailure(
            stage: .emptyPasteboard,
            detail: "拖拽进入接收区但 Pasteboard 未宣告任何类型（WebKit 未提供图片载荷）",
            pasteboardTypes: types
        )
        present(.failure(failure))
    }

    /// 把采集记录导成 Markdown 表格放回剪贴板，省掉手工誊抄逐图记录。
    func copyLog() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(log.markdownTable(), forType: .string)
        status = "已复制 \(log.entries.count) 条记录到剪贴板"
    }

    private func consume(snapshot: CapturePasteboardSnapshot, isDrag: Bool) {
        lastTypes = snapshot.types
        let transport: CaptureTransport
        switch receiver.payload(from: snapshot) {
        case .success(let payload):
            switch (isDrag, payload) {
            case (false, .bytes): transport = .clipboardBytes
            case (false, .fileURL): transport = .clipboardFile
            case (false, .remoteURL): transport = .clipboardURL
            case (true, .bytes): transport = .dragBytes
            case (true, .fileURL): transport = .dragFile
            case (true, .remoteURL): transport = .dragURL
            }
            status = "正在接收…"
            Task { @MainActor in
                let captured = await receiver.receive(
                    payload, transport: transport, sourcePageURL: browser.pageURL,
                    pasteboardTypes: snapshot.types
                )
                present(captured)
            }
        case .failure(let failure):
            present(.failure(failure))
        }
    }

    private func present(_ result: CaptureResult) {
        self.result = result
        log.append(result: result, pasteboardTypes: lastTypes, currentPageURL: browser.pageURL)
        switch result {
        case .success(let success):
            status = "成功：\(success.transport.rawValue)，耗时 \(Int(success.elapsed * 1_000)) ms"
        case .failure(let failure):
            status = "失败：\(failure.message)（\(failure.detail)）"
        }
    }
}

struct WebWorkspaceView: View {
    @StateObject private var model = WebWorkspaceModel()

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            HSplitView {
                WebViewHost(
                    controller: model.browser,
                    initialURL: URL(string: "https://huaban.com/")!
                )
                .frame(minWidth: 520)

                CapturePane(model: model)
                    .frame(minWidth: 300, idealWidth: 360)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 900, minHeight: 620)
    }

    private var navigationBar: some View {
        HStack(spacing: 8) {
            Button(action: model.browser.goBack) { Image(systemName: "chevron.left") }
                .disabled(!model.browser.canGoBack)
            Button(action: model.browser.goForward) { Image(systemName: "chevron.right") }
                .disabled(!model.browser.canGoForward)
            Button(action: model.browser.reload) { Image(systemName: "arrow.clockwise") }
            TextField("https://", text: $model.address)
                .textFieldStyle(.roundedBorder)
                .onSubmit(model.openAddress)
            Button("打开", action: model.openAddress)
            Menu("快捷入口") {
                Button("花瓣") { model.address = "https://huaban.com/"; model.openAddress() }
                Button("Pinterest") { model.address = "https://www.pinterest.com/"; model.openAddress() }
                Divider()
                Button("本地对照页", action: model.openFixture)
            }
        }
        .padding(10)
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("状态：\(model.status)")
            if !model.lastTypes.isEmpty {
                Text("收到的 Pasteboard 类型：\(model.lastTypes.joined(separator: ", "))")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CapturePane: View {
    @ObservedObject var model: WebWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("图片接收区").font(.headline)
            CaptureDropZone(onDrop: model.captureDrop, onRejected: model.captureRejectedDrop)
                .overlay {
                    preview
                        .padding(12)
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, minHeight: 260)

            HStack {
                Button("从剪贴板采集", action: model.captureClipboard)
                    .keyboardShortcut("v", modifiers: [.command, .option])
                Button("复制记录", action: model.copyLog)
                    .disabled(model.log.entries.isEmpty)
            }

            metadata
            Divider()
            logList
        }
        .padding(16)
    }

    @ViewBuilder private var logList: some View {
        HStack {
            Text("采集记录（\(model.log.entries.count)/20）").font(.subheadline)
            Spacer()
            Button("清空", action: model.log.clear).buttonStyle(.link)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(model.log.entries.enumerated()), id: \.element.id) { index, entry in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(model.log.entries.count - index).")
                            .foregroundStyle(.secondary)
                        Text(entry.summary)
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder private var preview: some View {
        switch model.result {
        case .success(let success):
            VStack(spacing: 8) {
                Image(nsImage: success.preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 185)
                Text("\(Int(success.pixelSize.width)) × \(Int(success.pixelSize.height)) px")
                    .font(.caption)
            }
        case .failure(let failure):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text(failure.message).font(.caption)
            }
            .foregroundStyle(.secondary)
        case nil:
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.title2)
                Text("从网页拖一张图片到这里")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var metadata: some View {
        switch model.result {
        case .success(let success):
            VStack(alignment: .leading, spacing: 4) {
                Text("来源：\(success.transport.rawValue)")
                Text("字节：\(success.byteCount) · 类型：\(success.mediaType ?? "未知")")
                Text("页面：\(CaptureLog.redactedPage(success.sourcePageURL) ?? "未加载")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .failure(let failure):
            Text("失败阶段：\(failure.stage.rawValue) · \(failure.detail)")
                .font(.caption)
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }
}

private final class NativeCaptureDropView: NSView {
    var onDrop: ((CapturePasteboardSnapshot) -> Void)?
    /// 进得来但宣告类型为空时上报，用来区分「WebKit 没发起拖拽」和「接收代码没接住」。
    var onRejected: (([String]) -> Void)?
    private var lastRejectedSignature: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // registerForDraggedTypes 按类型名精确匹配，不做协议一致性推导，所以要把
        // WebKit 拖拽实际会写上的类型尽量列全，否则 draggingEntered 根本不会被调用。
        registerForDraggedTypes([
            .png, .tiff, .fileURL, .URL, .string, .html,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.image"),
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType("public.url-name"),
            NSPasteboard.PasteboardType("com.compuserve.gif"),
            NSPasteboard.PasteboardType("com.apple.webarchive"),
            NSPasteboard.PasteboardType("Apple Web Archive pasteboard type"),
            NSPasteboard.PasteboardType("Apple HTML pasteboard type"),
            NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        resolve(sender)
    }

    // 不实现的话默认实现可能让光标退回禁止状态，拖拽看起来“进不来”。
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        resolve(sender)
    }

    private func resolve(_ sender: NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types?.map(\.rawValue) ?? []
        guard !types.isEmpty else {
            // draggingUpdated 会高频触发，同一次拖拽只上报一次。
            let signature = "empty"
            if lastRejectedSignature != signature {
                lastRejectedSignature = signature
                onRejected?([])
            }
            return []
        }
        lastRejectedSignature = nil
        return .copy
    }

    override func prepareForDragOperation(_: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let types = pasteboard.types?.map(\.rawValue) ?? []
        var dataByType: [String: Data] = [:]
        var stringsByType: [String: String] = [:]
        for rawType in types {
            let type = NSPasteboard.PasteboardType(rawType)
            if let data = pasteboard.data(forType: type) { dataByType[rawType] = data }
            if let value = pasteboard.string(forType: type) { stringsByType[rawType] = value }
        }
        onDrop?(CapturePasteboardSnapshot(
            types: types, dataByType: dataByType, stringsByType: stringsByType
        ))
        return true
    }
}

private struct CaptureDropZone: NSViewRepresentable {
    let onDrop: (CapturePasteboardSnapshot) -> Void
    let onRejected: ([String]) -> Void

    func makeNSView(context: Context) -> NativeCaptureDropView {
        let view = NativeCaptureDropView()
        view.onDrop = onDrop
        view.onRejected = onRejected
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        return view
    }

    func updateNSView(_ view: NativeCaptureDropView, context _: Context) {
        view.onDrop = onDrop
        view.onRejected = onRejected
    }
}

@MainActor
final class LocalFixturePage {
    let directory: URL
    let indexURL: URL

    /// 固定路径而非 UUID 目录：上一次异常退出留下的夹具会被本次启动顺手清掉。
    nonisolated static var sharedDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WebCaptureSpikeFixture", isDirectory: true)
    }

    nonisolated static func cleanupSharedDirectory() {
        try? FileManager.default.removeItem(at: sharedDirectory)
    }

    init() {
        directory = Self.sharedDirectory
        indexURL = directory.appendingPathComponent("index.html")
        Self.cleanupSharedDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writeFixtures()
    }

    private func writeFixtures() {
        // 每个样本用不同尺寸与颜色，方便在第 8 章逐图记录里一一对应。
        let samples: [(name: String, data: Data)] = [
            ("opaque.png", Self.syntheticImage(type: .png, transparent: false, width: 240)),
            ("photo.jpg", Self.syntheticImage(type: .jpeg, transparent: false, width: 320)),
            ("alpha.png", Self.syntheticImage(type: .png, transparent: true, width: 200))
        ]
        for sample in samples {
            try? sample.data.write(to: directory.appendingPathComponent(sample.name))
        }
        let html = """
        <!doctype html><meta charset="utf-8"><style>
        body { font: 13px -apple-system; padding: 20px; }
        figure { display: inline-block; margin: 6px; text-align: center; }
        img, .background, canvas { width: 190px; height: 133px; object-fit: contain;
          border: 1px solid #aaa; background-color: #f4f4f4; }
        .background { background: center / contain no-repeat url('alpha.png'); display: block; }
        figcaption { color: #444; margin-top: 4px; }
        </style>
        <h1>WebCaptureSpike 本地对照页</h1>
        <p>逐个拖到右侧接收区；或右键「拷贝图像」后点「从剪贴板采集」。</p>

        <figure><img alt="opaque-png" src="opaque.png"><figcaption>1 普通 PNG</figcaption></figure>
        <figure><img alt="jpeg" src="photo.jpg"><figcaption>2 JPEG</figcaption></figure>
        <figure><img alt="alpha-png" src="alpha.png"><figcaption>3 透明 PNG</figcaption></figure>
        <figure><img alt="srcset" src="photo.jpg" srcset="photo.jpg 1x, opaque.png 2x"
            width="190" height="133"><figcaption>4 srcset</figcaption></figure>
        <figure><span class="background"></span><figcaption>5 CSS 背景图</figcaption></figure>
        <figure><canvas id="canvas" width="190" height="133"></canvas><figcaption>6 Canvas</figcaption></figure>
        <figure><img id="blob" alt="blob" width="190" height="133"><figcaption>7 blob:</figcaption></figure>
        <figure><div style="width:190px;height:133px;border:1px solid #aaa;box-sizing:border-box">纯文字</div>
          <figcaption>8 反例：非图片</figcaption></figure>

        <script>
        const source = new Image();
        source.onload = () => {
          document.querySelector('#canvas').getContext('2d').drawImage(source, 0, 0, 190, 133);
        };
        source.src = 'opaque.png';
        fetch('photo.jpg')
          .then(response => response.blob())
          .then(blob => { document.querySelector('#blob').src = URL.createObjectURL(blob); });
        </script>
        """
        try? html.data(using: .utf8)?.write(to: indexURL)
    }

    /// 代码生成的公开夹具，不含任何用户真实图片或网站截图。
    static func syntheticImage(
        type: NSBitmapImageRep.FileType, transparent: Bool, width: Int
    ) -> Data {
        let height = Int(Double(width) * 0.7)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if !transparent {
            NSColor.systemBlue.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        }
        NSColor.systemYellow.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: Double(width) * 0.25, y: Double(height) * 0.2,
            width: Double(width) * 0.5, height: Double(height) * 0.6
        )).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: type, properties: [:])!
    }
}
