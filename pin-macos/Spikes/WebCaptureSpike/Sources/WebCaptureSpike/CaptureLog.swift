import Foundation

struct CaptureLogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let transport: CaptureTransport?
    let outcome: String
    let elapsed: TimeInterval?
    let pixelSize: CGSize?
    let byteCount: Int?
    let pasteboardTypes: [String]
    let page: String?

    /// 一行可读摘要，同时用于界面和“复制记录”导出的表格。
    var summary: String {
        let head = "\(transport?.rawValue ?? "失败") · \(outcome)"
        guard let pixelSize, let byteCount else {
            return "\(head) · 类型 \(pasteboardTypes.joined(separator: ","))"
        }
        let milliseconds = Int((elapsed ?? 0) * 1_000)
        return "\(head) · \(Int(pixelSize.width))×\(Int(pixelSize.height))px · "
            + "\(byteCount) 字节 · \(milliseconds)ms · \(page ?? "无页面")"
    }

    var markdownRow: String {
        let action = transport?.rawValue ?? "未记录"
        let types = pasteboardTypes.joined(separator: "<br>")
        let stamp = date.formatted(date: .omitted, time: .standard)
        let where_ = page ?? "无页面 URL"
        if let pixelSize, let byteCount {
            let milliseconds = Int((elapsed ?? 0) * 1_000)
            return "| \(stamp) | \(where_) | \(action) | 成功 | 稍后补 | "
                + "\(Int(pixelSize.width))×\(Int(pixelSize.height)) | \(byteCount) | \(milliseconds)ms | \(types) | — |"
        }
        return "| \(stamp) | \(where_) | \(action) | 失败 | 稍后补 | — | — | — | \(types) | \(outcome) |"
    }
}

@MainActor
final class CaptureLog: ObservableObject {
    @Published private(set) var entries: [CaptureLogEntry] = []

    func append(
        result: CaptureResult, pasteboardTypes: [String] = [], currentPageURL: URL? = nil
    ) {
        let entry: CaptureLogEntry
        switch result {
        case .success(let success):
            entry = CaptureLogEntry(
                date: Date(), transport: success.transport, outcome: "成功",
                elapsed: success.elapsed, pixelSize: success.pixelSize,
                byteCount: success.byteCount, pasteboardTypes: pasteboardTypes,
                page: Self.redactedPage(success.sourcePageURL ?? currentPageURL)
            )
        case .failure(let failure):
            entry = CaptureLogEntry(
                date: Date(), transport: nil,
                outcome: "\(failure.message)（阶段 \(failure.stage.rawValue)）",
                elapsed: nil, pixelSize: nil, byteCount: nil,
                pasteboardTypes: failure.pasteboardTypes,
                page: Self.redactedPage(currentPageURL)
            )
        }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(20))
    }

    func clear() { entries = [] }

    /// 导出成 Markdown 表格，方便直接贴进第 8 章的逐图记录。
    func markdownTable() -> String {
        let header = "| 时间 | 网站位置 | 首选动作 | 结果 | 操作步数 | 像素 | 字节 | 耗时 | 收到的数据类型 | 失败原因 |\n"
            + "| --- | --- | --- | --- | ---: | --- | ---: | ---: | --- | --- |"
        return ([header] + entries.reversed().map(\.markdownRow)).joined(separator: "\n")
    }

    static func redactedPage(_ url: URL?) -> String? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string
    }
}
