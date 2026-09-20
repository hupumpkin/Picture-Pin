import Foundation

/// `--library-report`（§3.7）：把素材库与库文件状态打印出来，供送审。
///
/// 为什么是个独立的入口而不是只在自检里跑：自检断言的是「**这个**临时库里
/// 有什么」，报告回答的是「**用户那份**库里有什么」。用户报「素材打不开」时，
/// 第一件要确认的事是那份库有没有那几张表、停在哪个版本、`-wal` 是不是还压着
/// 一批没合并的写入——这些只有对着真实库读才拿得到。
///
/// 分成两层：`render` 是纯函数（吃什么值、出什么字，自检直接钉），
/// `runAndExit` 只负责打开库、把值收进来、打印。要送审的格式全在 `render` 里，
/// 改格式不用碰库。
enum LibraryReport {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--library-report")
    }

    static func runAndExit() async -> Never {
        let environment = AppEnvironment.resolveForLaunch(
            dataDirectoryOverride: AppEnvironment.overrideDirectory(in: CommandLine.arguments)
        )
        let directory = environment.dataDirectory
        do {
            let database = try LibraryDatabase.open(at: directory)
            let report = render(
                directory: directory,
                structure: try await database.structure(),
                journalMode: try await database.journalMode(),
                fileSizes: database.fileSizes(),
                assets: try await AssetStore(database: database, root: directory).allAssets(),
                boardCount: try await SceneStore(database: database).boardCount(),
                elementCount: try await SceneStore(database: database).elementCount()
            )
            print(report)
            exit(0)
        } catch let error as DatabaseOpenError {
            // 打不开本身就是报告要报的头一条：路径与原因原样打出来，
            // 送审的人第一眼看到的就是"为什么打不开"。
            print("打不开素材库：\(error.errorDescription ?? error.path)")
            exit(1)
        } catch {
            print("读素材库失败：\(error)")
            exit(1)
        }
    }

    /// 报告正文。**纯函数**：同入参必同出参，自检按段落断言。
    ///
    /// 少一段比多一段糟得多——送审的人会默认"没打出来的就是没有"，
    /// 所以每个段落的标题都必须在，哪怕内容是零（表 0 张、素材 0 条）。
    static func render(
        directory: URL,
        structure: LibraryStructure,
        journalMode: String,
        fileSizes: (main: Int, wal: Int, shm: Int),
        assets: [AssetRecord],
        boardCount: Int,
        elementCount: Int
    ) -> String {
        var lines: [String] = []
        lines.append("Pin 素材库报告")
        lines.append("数据目录：\(directory.path)")
        lines.append("")

        lines.append("【库结构】")
        lines.append("版本：user_version = \(structure.version)")
        lines.append("表（\(structure.tables.count) 张）：\(structure.tables.joined(separator: ", "))")
        lines.append("索引（\(structure.indexes.count) 个）：\(structure.indexes.joined(separator: ", "))")
        for table in structure.tables.sorted() {
            let columns = structure.columns[table] ?? []
            lines.append("  \(table)（\(columns.count) 列）：\(columns.joined(separator: ", "))")
        }
        lines.append("")

        lines.append("【库文件】")
        lines.append("journal 模式：\(journalMode)")
        lines.append("\(LibraryDatabase.fileName)：\(fileSizes.main) 字节")
        lines.append("\(LibraryDatabase.fileName)-wal：\(fileSizes.wal) 字节")
        lines.append("\(LibraryDatabase.fileName)-shm：\(fileSizes.shm) 字节")
        lines.append("")

        lines.append("【内容】")
        lines.append("画布：\(boardCount) 块")
        lines.append("元素：\(elementCount) 个")
        lines.append("素材：\(assets.count) 条")
        for asset in assets {
            lines.append(
                "  - \(asset.originalFilename)"
                + "  \(Int(asset.pixelSize.width))×\(Int(asset.pixelSize.height))"
                + "  \(asset.byteCount) 字节"
                + "  添加于 \(Self.dateFormatter.string(from: asset.addedAt))"
            )
        }
        return lines.joined(separator: "\n")
    }

    /// 固定格式 + UTC，保证报告在不同机器、不同时区上读法一致——
    /// 送审的人在两台机器上看到的同一行必须是同一句话。
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
