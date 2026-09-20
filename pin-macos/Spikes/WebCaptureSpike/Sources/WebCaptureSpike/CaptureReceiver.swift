import AppKit
import ImageIO
import UniformTypeIdentifiers

protocol RemoteImageLoading: Sendable {
    func load(_ url: URL, limit: Int) async throws -> RemoteImageData
}

struct RemoteImageData: Sendable {
    let data: Data
    let mediaType: String?
}

struct URLSessionRemoteImageLoader: RemoteImageLoading {
    func load(_ url: URL, limit: Int) async throws -> RemoteImageData {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)
        guard data.count <= limit else { throw RemoteLoadError.tooLarge }
        let mediaType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
        return RemoteImageData(data: data, mediaType: mediaType)
    }
}

enum RemoteLoadError: Error {
    case tooLarge
}

@MainActor
final class CaptureReceiver {
    static let maximumByteCount = 50 * 1_024 * 1_024

    private let remoteLoader: any RemoteImageLoading

    init(remoteLoader: any RemoteImageLoading = URLSessionRemoteImageLoader()) {
        self.remoteLoader = remoteLoader
    }

    func snapshot(of pasteboard: NSPasteboard) -> CapturePasteboardSnapshot {
        let types = pasteboard.types?.map(\.rawValue) ?? []
        var dataByType: [String: Data] = [:]
        var stringsByType: [String: String] = [:]
        for rawType in types {
            let type = NSPasteboard.PasteboardType(rawType)
            if let data = pasteboard.data(forType: type) { dataByType[rawType] = data }
            if let value = pasteboard.string(forType: type) { stringsByType[rawType] = value }
        }
        return CapturePasteboardSnapshot(
            types: types, dataByType: dataByType, stringsByType: stringsByType
        )
    }

    func payload(from snapshot: CapturePasteboardSnapshot) -> Result<CapturePayload, CaptureFailure> {
        guard !snapshot.types.isEmpty else {
            return .failure(CaptureFailure(
                stage: .emptyPasteboard, detail: "Pasteboard 中没有声明类型", pasteboardTypes: []
            ))
        }

        // A raw image always wins over a file or URL. This avoids redownloading a
        // network resource that WebKit has already placed on the pasteboard.
        for rawType in snapshot.types where isImageType(rawType) {
            if let data = snapshot.dataByType[rawType], !data.isEmpty {
                return .success(.bytes(data, declaredType: rawType))
            }
        }

        let fileType = NSPasteboard.PasteboardType.fileURL.rawValue
        if let raw = snapshot.stringsByType[fileType] ?? stringData(snapshot.dataByType[fileType]),
           let url = URL(string: raw), url.isFileURL {
            return .success(.fileURL(url))
        }

        let urlType = NSPasteboard.PasteboardType.URL.rawValue
        if let raw = snapshot.stringsByType[urlType] ?? stringData(snapshot.dataByType[urlType]),
           let url = URL(string: raw) {
            return .success(.remoteURL(url))
        }

        return .failure(CaptureFailure(
            stage: .unsupportedPasteboard,
            detail: "未找到图片字节、文件 URL 或网络 URL", pasteboardTypes: snapshot.types
        ))
    }

    func receive(
        _ payload: CapturePayload,
        transport: CaptureTransport,
        sourcePageURL: URL? = nil,
        pasteboardTypes: [String] = []
    ) async -> CaptureResult {
        let start = Date()
        switch payload {
        case .bytes(let data, let declaredType):
            return decode(
                data, declaredType: declaredType, transport: transport,
                sourcePageURL: sourcePageURL, start: start, pasteboardTypes: pasteboardTypes
            )

        case .fileURL(let url):
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if let byteCount = attributes[.size] as? NSNumber,
                   byteCount.intValue > Self.maximumByteCount {
                    return failure(.tooLarge, "文件大小为 \(byteCount.intValue) 字节", pasteboardTypes)
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                return decode(
                    data, declaredType: UTType(filenameExtension: url.pathExtension)?.identifier,
                    transport: transport, sourcePageURL: sourcePageURL,
                    start: start, pasteboardTypes: pasteboardTypes
                )
            } catch {
                return failure(.fileRead, error.localizedDescription, pasteboardTypes)
            }

        case .remoteURL(let url):
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return failure(.invalidURL, "仅接受 http / https URL", pasteboardTypes)
            }
            do {
                let response = try await remoteLoader.load(url, limit: Self.maximumByteCount)
                return decode(
                    response.data, declaredType: response.mediaType, transport: transport,
                    sourcePageURL: sourcePageURL, start: start, pasteboardTypes: pasteboardTypes
                )
            } catch RemoteLoadError.tooLarge {
                return failure(.tooLarge, "响应体超过 50 MB", pasteboardTypes)
            } catch {
                return failure(.network, error.localizedDescription, pasteboardTypes)
            }
        }
    }

    private func decode(
        _ data: Data,
        declaredType: String?,
        transport: CaptureTransport,
        sourcePageURL: URL?,
        start: Date,
        pasteboardTypes: [String]
    ) -> CaptureResult {
        guard data.count <= Self.maximumByteCount else {
            return failure(.tooLarge, "载荷大小为 \(data.count) 字节", pasteboardTypes)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return failure(.decode, "ImageIO 无法创建图片", pasteboardTypes)
        }
        let size = CGSize(width: image.width, height: image.height)
        return .success(CaptureSuccess(
            image: image, byteCount: data.count, pixelSize: size,
            mediaType: declaredType, sourcePageURL: sourcePageURL,
            transport: transport, elapsed: Date().timeIntervalSince(start)
        ))
    }

    private func failure(
        _ stage: CaptureStage, _ detail: String, _ pasteboardTypes: [String]
    ) -> CaptureResult {
        .failure(CaptureFailure(stage: stage, detail: detail, pasteboardTypes: pasteboardTypes))
    }

    private func isImageType(_ rawType: String) -> Bool {
        UTType(rawType)?.conforms(to: .image) == true
    }

    private func stringData(_ data: Data?) -> String? {
        guard let data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
