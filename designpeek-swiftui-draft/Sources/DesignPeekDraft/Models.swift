import SwiftUI

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case library = "截图"
    case analysis = "分析"

    var id: Self { self }
}

enum LibraryFilter: Hashable {
    case inbox
    case favorites
    case folder(String)
}

struct MaterialFolder: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let count: Int
}

struct AnalysisFolder: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let count: Int
}

struct AnalysisDraft: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let imageCount: Int
    let completed: Bool
}

struct MockCapture: Identifiable, Hashable {
    let id = UUID()
    let app: String
    let time: String
    let palette: CapturePalette
    let variant: Int
}

enum CapturePalette: Int, Hashable {
    case obsidian
    case cobalt
    case coral
    case mint
    case paper
    case plum

    var background: Color {
        switch self {
        case .obsidian: return Color(red: 0.07, green: 0.07, blue: 0.08)
        case .cobalt: return Color(red: 0.08, green: 0.18, blue: 0.45)
        case .coral: return Color(red: 0.93, green: 0.28, blue: 0.23)
        case .mint: return Color(red: 0.13, green: 0.52, blue: 0.42)
        case .paper: return Color(red: 0.94, green: 0.92, blue: 0.86)
        case .plum: return Color(red: 0.34, green: 0.16, blue: 0.37)
        }
    }

    var accent: Color {
        switch self {
        case .obsidian: return Color(red: 0.87, green: 0.73, blue: 0.42)
        case .cobalt: return Color(red: 0.29, green: 0.69, blue: 0.98)
        case .coral: return Color(red: 1.0, green: 0.83, blue: 0.35)
        case .mint: return Color(red: 0.74, green: 0.93, blue: 0.65)
        case .paper: return Color(red: 0.17, green: 0.39, blue: 0.34)
        case .plum: return Color(red: 0.91, green: 0.58, blue: 0.69)
        }
    }

    var foreground: Color { self == .paper ? .black : .white }
}

enum PreviewData {
    static let materialFolders = [
        MaterialFolder(name: "私人酒窖", count: 38),
        MaterialFolder(name: "新品频道", count: 31),
        MaterialFolder(name: "签到与任务", count: 17)
    ]

    static let analysisFolders = [
        AnalysisFolder(name: "品牌心智", count: 2),
        AnalysisFolder(name: "增长机制", count: 1)
    ]

    static let analyses = [
        AnalysisDraft(title: "新品频道如何建立品质感", imageCount: 6, completed: true),
        AnalysisDraft(title: "会员页的视觉表达", imageCount: 4, completed: false)
    ]

    static let captures: [MockCapture] = [
        .init(app: "小红书", time: "11:09", palette: .obsidian, variant: 0),
        .init(app: "小红书", time: "10:52", palette: .cobalt, variant: 1),
        .init(app: "淘宝", time: "10:41", palette: .coral, variant: 2),
        .init(app: "微信", time: "10:28", palette: .mint, variant: 3),
        .init(app: "京东", time: "10:16", palette: .paper, variant: 4),
        .init(app: "小红书", time: "09:58", palette: .plum, variant: 5),
        .init(app: "淘宝", time: "09:43", palette: .paper, variant: 6),
        .init(app: "京东", time: "09:21", palette: .coral, variant: 7),
        .init(app: "微信", time: "08:56", palette: .mint, variant: 8),
        .init(app: "小红书", time: "08:40", palette: .obsidian, variant: 9)
    ]
}
