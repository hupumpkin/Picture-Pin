import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import WebCaptureSpike

// MARK: - Fixtures

enum FixtureImage {
    /// 8x8 opaque PNG produced by ImageIO, not by hand-rolled bytes.
    static func png() -> Data { encode(type: "public.png") }
    static func jpeg() -> Data { encode(type: "public.jpeg") }

    private static func encode(type: String) -> Data {
        let width = 8
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            pixels[index * 4 + 0] = 30
            pixels[index * 4 + 1] = 120
            pixels[index * 4 + 2] = 240
            pixels[index * 4 + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output, type as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

struct StubRemoteLoader: RemoteImageLoading {
    enum Behavior: Sendable {
        case succeed(Data, mediaType: String?)
        case fail(any Error)
    }

    let behavior: Behavior

    func load(_ url: URL, limit: Int) async throws -> RemoteImageData {
        switch behavior {
        case .succeed(let data, let mediaType):
            guard data.count <= limit else { throw RemoteLoadError.tooLarge }
            return RemoteImageData(data: data, mediaType: mediaType)
        case .fail(let error):
            throw error
        }
    }
}

private struct StubNetworkError: Error {}

@MainActor
private func makeReceiver(_ behavior: StubRemoteLoader.Behavior = .succeed(Data(), mediaType: nil))
    -> CaptureReceiver
{
    CaptureReceiver(remoteLoader: StubRemoteLoader(behavior: behavior))
}

private func snapshot(
    types: [String],
    data: [String: Data] = [:],
    strings: [String: String] = [:]
) -> CapturePasteboardSnapshot {
    CapturePasteboardSnapshot(types: types, dataByType: data, stringsByType: strings)
}

// MARK: - Payload selection

@MainActor
@Suite("剪贴板载荷选择")
struct PayloadSelectionTests {
    @Test("非图片纯文本剪贴板被判为不支持，并列出全部类型")
    func plainTextIsUnsupported() {
        let pasteboard = snapshot(
            types: ["public.utf8-plain-text"],
            data: ["public.utf8-plain-text": Data("hello".utf8)],
            strings: ["public.utf8-plain-text": "hello"]
        )
        switch makeReceiver().payload(from: pasteboard) {
        case .success:
            Issue.record("纯文本不应产生载荷")
        case .failure(let failure):
            #expect(failure.stage == .unsupportedPasteboard)
            #expect(failure.message == "不支持的剪贴板内容")
            #expect(failure.pasteboardTypes == ["public.utf8-plain-text"])
        }
    }

    @Test("空剪贴板走到 emptyPasteboard 阶段")
    func emptyPasteboard() {
        switch makeReceiver().payload(from: snapshot(types: [])) {
        case .success:
            Issue.record("空剪贴板不应产生载荷")
        case .failure(let failure):
            #expect(failure.stage == .emptyPasteboard)
            #expect(failure.message == "剪贴板无图片")
        }
    }

    @Test("图片字节优先于同一份剪贴板里的 URL")
    func bytesWinOverURL() {
        let png = FixtureImage.png()
        let pasteboard = snapshot(
            types: ["public.png", "public.url"],
            data: ["public.png": png],
            strings: ["public.url": "https://example.com/other.png"]
        )
        switch makeReceiver().payload(from: pasteboard) {
        case .success(.bytes(let data, let declaredType)):
            #expect(data == png)
            #expect(declaredType == "public.png")
        case .success(let other):
            Issue.record("应选字节，实际为 \(other)")
        case .failure(let failure):
            Issue.record("不应失败：\(failure.message)")
        }
    }

    @Test("非图片类型声明不参与图片字节判断")
    func fileURLIsNotTreatedAsImageBytes() {
        let pasteboard = snapshot(
            types: ["public.file-url"],
            strings: ["public.file-url": "file:///tmp/not-an-image.txt"]
        )
        switch makeReceiver().payload(from: pasteboard) {
        case .success(.fileURL(let url)):
            #expect(url.path == "/tmp/not-an-image.txt")
        case .success(let other):
            Issue.record("应为 fileURL，实际为 \(other)")
        case .failure(let failure):
            Issue.record("不应失败：\(failure.message)")
        }
    }

    @Test("重复声明的同一 Pasteboard 类型只产出一次结果")
    func duplicatePasteboardTypesProduceOneResult() {
        let png = FixtureImage.png()
        // "public.image" 与 "public.png" 都符合图片语义，且两者都带字节。
        let pasteboard = snapshot(
            types: ["public.image", "public.png", "public.tiff"],
            data: ["public.image": png, "public.png": png, "public.tiff": png]
        )
        var produced = 0
        var chosen: String?
        if case .success(.bytes(_, let declaredType)) = makeReceiver().payload(from: pasteboard) {
            produced += 1
            chosen = declaredType
        }
        #expect(produced == 1)
        #expect(chosen == "public.image")
    }

    @Test("URL 顺序回退：先文件 URL，再网络 URL")
    func fileURLWinsOverRemoteURL() {
        let pasteboard = snapshot(
            types: ["public.file-url", "public.url"],
            strings: [
                "public.file-url": "file:///tmp/a.png",
                "public.url": "https://example.com/a.png"
            ]
        )
        switch makeReceiver().payload(from: pasteboard) {
        case .success(.fileURL(let url)):
            #expect(url.isFileURL)
        default:
            Issue.record("文件 URL 应优先于网络 URL")
        }
    }
}

// MARK: - Receive pipeline

@MainActor
@Suite("采集管线")
struct ReceivePipelineTests {
    @Test("图片字节可解码成图片并带回像素尺寸")
    func bytesDecode() async {
        let png = FixtureImage.png()
        let result = await makeReceiver().receive(
            .bytes(png, declaredType: "public.png"),
            transport: .clipboardBytes,
            sourcePageURL: URL(string: "https://huaban.com/pins/1")!
        )
        switch result {
        case .success(let success):
            #expect(success.pixelSize == CGSize(width: 8, height: 8))
            #expect(success.byteCount == png.count)
            #expect(success.transport == .clipboardBytes)
            #expect(success.sourcePageURL?.absoluteString == "https://huaban.com/pins/1")
        case .failure(let failure):
            Issue.record("不应失败：\(failure.message)")
        }
    }

    @Test("非 HTTP(S) 的 URL 被拒绝，且落在 invalidURL 阶段")
    func rejectsNonHTTPScheme() async {
        for raw in ["file:///tmp/a.png", "data:image/png;base64,AAAA", "ftp://example.com/a.png"] {
            let result = await makeReceiver().receive(
                .remoteURL(URL(string: raw)!), transport: .clipboardURL
            )
            guard case .failure(let failure) = result else {
                Issue.record("\(raw) 不应被接受")
                continue
            }
            #expect(failure.stage == .invalidURL)
            #expect(failure.message == "图片 URL 无效")
        }
    }

    @Test("响应超过大小限制时落在 tooLarge 阶段")
    func rejectsOversizedResponse() async {
        let limit = CaptureReceiver.maximumByteCount
        let receiver = CaptureReceiver(
            remoteLoader: StubRemoteLoader(
                behavior: .fail(RemoteLoadError.tooLarge)
            )
        )
        let result = await receiver.receive(
            .remoteURL(URL(string: "https://example.com/big.png")!), transport: .clipboardURL
        )
        guard case .failure(let failure) = result else {
            Issue.record("超限响应应失败")
            return
        }
        #expect(failure.stage == .tooLarge)
        #expect(failure.message == "图片超过 50 MB 限制")
        #expect(limit == 50 * 1_024 * 1_024)
    }

    @Test("超过上限的字节载荷在解码前就被拒绝")
    func rejectsOversizedBytes() async {
        let oversized = Data(count: CaptureReceiver.maximumByteCount + 1)
        let result = await makeReceiver().receive(
            .bytes(oversized, declaredType: "public.png"), transport: .clipboardBytes
        )
        guard case .failure(let failure) = result else {
            Issue.record("超限字节应失败")
            return
        }
        #expect(failure.stage == .tooLarge)
    }

    @Test("无法解码的字节落在 decode 阶段，且不崩溃")
    func rejectsUndecodableBytes() async {
        let junk = Data("this is definitely not an image".utf8)
        let result = await makeReceiver().receive(
            .bytes(junk, declaredType: "public.png"), transport: .clipboardBytes
        )
        guard case .failure(let failure) = result else {
            Issue.record("垃圾字节应失败")
            return
        }
        #expect(failure.stage == .decode)
        #expect(failure.message == "收到的内容不是可解码图片")
    }

    @Test("Content-Type 撒谎时仍以 ImageIO 解码结果为准")
    func contentTypedLieIsCaughtByDecoding() async {
        let receiver = CaptureReceiver(
            remoteLoader: StubRemoteLoader(
                behavior: .succeed(Data("not really a png".utf8), mediaType: "image/png")
            )
        )
        let result = await receiver.receive(
            .remoteURL(URL(string: "https://example.com/lies.png")!), transport: .clipboardURL
        )
        guard case .failure(let failure) = result else {
            Issue.record("伪装的 png 应解码失败")
            return
        }
        #expect(failure.stage == .decode)
    }

    @Test("网络失败落在 network 阶段")
    func networkFailureStage() async {
        let receiver = CaptureReceiver(
            remoteLoader: StubRemoteLoader(behavior: .fail(StubNetworkError()))
        )
        let result = await receiver.receive(
            .remoteURL(URL(string: "https://example.com/a.png")!), transport: .clipboardURL
        )
        guard case .failure(let failure) = result else {
            Issue.record("网络失败应返回 failure")
            return
        }
        #expect(failure.stage == .network)
        #expect(failure.message == "网络下载失败")
    }

    @Test("不存在的本地文件落在 fileRead 阶段")
    func missingFileStage() async {
        let missing = URL(fileURLWithPath: "/tmp/webcapturespike-does-not-exist-\(UUID().uuidString).png")
        let result = await makeReceiver().receive(.fileURL(missing), transport: .clipboardFile)
        guard case .failure(let failure) = result else {
            Issue.record("缺失文件应失败")
            return
        }
        #expect(failure.stage == .fileRead)
        #expect(failure.message == "读取本地图片失败")
    }

    @Test("JPEG 与 PNG 都能解码，媒体类型按声明回传")
    func decodesJPEGAndPNG() async {
        let receiver = makeReceiver()
        for (data, type) in [(FixtureImage.png(), "public.png"), (FixtureImage.jpeg(), "public.jpeg")] {
            let result = await receiver.receive(.bytes(data, declaredType: type), transport: .dragBytes)
            guard case .success(let success) = result else {
                Issue.record("\(type) 应解码成功")
                continue
            }
            #expect(success.mediaType == type)
            #expect(success.byteCount == data.count)
        }
    }
}

// MARK: - Logging hygiene

@MainActor
@Suite("日志脱敏")
struct CaptureLogTests {
    @Test("页面 URL 去掉 query、fragment 与 userinfo")
    func redactsSensitiveURLParts() {
        let url = URL(string: "https://user:pw@huaban.com/pins/1?token=SECRET#hash")!
        let redacted = CaptureLog.redactedPage(url)
        #expect(redacted == "https://huaban.com/pins/1")
        #expect(!(redacted ?? "").contains("SECRET"))
        #expect(!(redacted ?? "").contains("pw"))
    }

    @Test("日志条目只保留非敏感字段")
    func logEntryCarriesNoSecrets() async {
        let log = CaptureLog()
        let png = FixtureImage.png()
        let result = await makeReceiver().receive(
            .bytes(png, declaredType: "public.png"),
            transport: .clipboardBytes,
            sourcePageURL: URL(string: "https://huaban.com/pins/2?token=SECRET")!
        )
        log.append(result: result, pasteboardTypes: ["public.png"])

        #expect(log.entries.count == 1)
        let entry = log.entries[0]
        let rendered = [
            entry.outcome,
            entry.page ?? "",
            entry.transport?.rawValue ?? "",
            entry.pasteboardTypes.joined(separator: ",")
        ].joined(separator: " | ")

        for forbidden in ["SECRET", "token", "cookie", "password", "pw"] {
            #expect(!rendered.lowercased().contains(forbidden.lowercased()))
        }
        #expect(entry.page == "https://huaban.com/pins/2")
    }

    @Test("日志最多保留 20 条")
    func logIsBounded() async {
        let log = CaptureLog()
        for index in 0..<25 {
            log.append(
                result: .failure(CaptureFailure(
                    stage: .decode, detail: "第 \(index) 次", pasteboardTypes: []
                ))
            )
        }
        #expect(log.entries.count == 20)
    }
}
