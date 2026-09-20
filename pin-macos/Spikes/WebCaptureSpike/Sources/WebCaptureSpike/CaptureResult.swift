import AppKit
import CoreGraphics
import Foundation

enum CaptureTransport: String, Sendable {
    case clipboardBytes = "剪贴板图片字节"
    case clipboardFile = "剪贴板文件"
    case clipboardURL = "剪贴板图片 URL"
    case dragBytes = "拖拽图片字节"
    case dragFile = "拖拽文件"
    case dragURL = "拖拽图片 URL"
    case webElementURL = "网页当前图片 URL"
}

enum CapturePayload {
    case bytes(Data, declaredType: String?)
    case fileURL(URL)
    case remoteURL(URL)
}

enum CaptureStage: String, Equatable, Sendable {
    case emptyPasteboard
    case unsupportedPasteboard
    case invalidURL
    case network
    case tooLarge
    case fileRead
    case decode
}

struct CaptureFailure: Error, Equatable, Sendable {
    let stage: CaptureStage
    let detail: String
    let pasteboardTypes: [String]

    var message: String {
        switch stage {
        case .emptyPasteboard: "剪贴板无图片"
        case .unsupportedPasteboard: "不支持的剪贴板内容"
        case .invalidURL: "图片 URL 无效"
        case .network: "网络下载失败"
        case .tooLarge: "图片超过 50 MB 限制"
        case .fileRead: "读取本地图片失败"
        case .decode: "收到的内容不是可解码图片"
        }
    }
}

struct CaptureSuccess {
    let image: CGImage
    let byteCount: Int
    let pixelSize: CGSize
    let mediaType: String?
    let sourcePageURL: URL?
    let transport: CaptureTransport
    let elapsed: TimeInterval

    var preview: NSImage { NSImage(cgImage: image, size: pixelSize) }
}

enum CaptureResult {
    case success(CaptureSuccess)
    case failure(CaptureFailure)
}

struct CapturePasteboardSnapshot: Sendable {
    let types: [String]
    let dataByType: [String: Data]
    let stringsByType: [String: String]

    init(types: [String], dataByType: [String: Data] = [:], stringsByType: [String: String] = [:]) {
        self.types = types
        self.dataByType = dataByType
        self.stringsByType = stringsByType
    }
}
