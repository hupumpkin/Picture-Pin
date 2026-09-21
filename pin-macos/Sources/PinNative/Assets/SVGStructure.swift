import Foundation

/// SVG 内部结构的只读索引。它只负责识别来自 Figma、Illustrator 等工具的 `<g>`
/// 层级，不把 XML 改写成另一套私有格式；编辑器据此进入/退出编组，保存仍回写
/// 原 SVG，因而外部工具的分组语义不会在导入时丢失。
struct SVGGroup: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let parentID: String?
    let depth: Int
}

/// 编辑器可直接操作的 SVG 绘制节点。`ordinal` 是没有 id 的外来 SVG 的稳定
/// 会话定位符；因此 Figma 导出的未命名 path 也不会因为缺 id 而变成不可编辑。
struct SVGEditableNode: Identifiable, Equatable, Sendable {
    let id: String
    let tag: String
    let label: String
    let ordinal: Int
    let text: String?
    let fill: String?
    let stroke: String?
}

enum SVGStructure {
    static func editableNodes(in source: String) -> [SVGEditableNode] {
        let pattern = #"<(path|rect|circle|ellipse|line|polyline|polygon|text)\b([^>]*)(?:>([^<]*)</text>|/?>)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        var nodes: [SVGEditableNode] = []
        expression.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match, let tagRange = Range(match.range(at: 1), in: source),
                  let attributesRange = Range(match.range(at: 2), in: source) else { return }
            let tag = String(source[tagRange]).lowercased()
            let attributes = String(source[attributesRange])
            let ordinal = nodes.count
            let id = attribute("id", in: attributes) ?? "node-\(ordinal)"
            let label = attribute("data-name", in: attributes) ?? attribute("aria-label", in: attributes) ?? id
            let text = match.range(at: 3).location == NSNotFound ? nil : Range(match.range(at: 3), in: source).map { String(source[$0]) }
            nodes.append(SVGEditableNode(id: id, tag: tag, label: label, ordinal: ordinal,
                                         text: text, fill: attribute("fill", in: attributes), stroke: attribute("stroke", in: attributes)))
        }
        return nodes
    }

    static func updating(_ source: String, node: SVGEditableNode, attribute name: String, value: String) -> String {
        let pattern = #"<(path|rect|circle|ellipse|line|polyline|polygon|text)\b[^>]*>"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return source }
        let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
        guard matches.indices.contains(node.ordinal), let range = Range(matches[node.ordinal].range, in: source) else { return source }
        let opening = String(source[range])
        let attributePattern = #"\b\#(name)\s*=\s*[\"'][^\"']*[\"']"#
        let replacement = "\(name)=\"\(value.replacingOccurrences(of: "\"", with: "&quot;"))\""
        let rewritten: String
        if let attributeExpression = try? NSRegularExpression(pattern: attributePattern),
           let found = attributeExpression.firstMatch(in: opening, range: NSRange(opening.startIndex..., in: opening)),
           let foundRange = Range(found.range, in: opening) {
            rewritten = opening.replacingCharacters(in: foundRange, with: replacement)
        } else {
            rewritten = opening.dropLast() + " \(replacement)>"
        }
        return source.replacingCharacters(in: range, with: rewritten)
    }
    static func groups(in source: String) -> [SVGGroup] {
        let pattern = #"<(/?)g\b([^>]*)>"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        var stack: [String] = []
        var result: [SVGGroup] = []
        var ordinal = 0
        expression.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match,
                  let closingRange = Range(match.range(at: 1), in: source),
                  let attributesRange = Range(match.range(at: 2), in: source)
            else { return }
            if source[closingRange] == "/" { _ = stack.popLast(); return }
            let attributes = String(source[attributesRange])
            ordinal += 1
            let id = attribute("id", in: attributes) ?? "group-\(ordinal)"
            let name = attribute("inkscape:label", in: attributes)
                ?? attribute("data-name", in: attributes)
                ?? attribute("aria-label", in: attributes)
                ?? id
            result.append(SVGGroup(id: id, name: name, parentID: stack.last, depth: stack.count))
            if !attributes.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/") { stack.append(id) }
        }
        return result
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        let pattern = #"\b\#(name)\s*=\s*[\"']([^\"']+)[\"']"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)),
              let range = Range(match.range(at: 1), in: attributes)
        else { return nil }
        return String(attributes[range])
    }
}
