import Foundation

/// 库出事时那份"导出诊断"文件的内容（C2 §4 第 4 条）。
///
/// ## 纯函数，和 `LibraryReport` 同一个道理
///
/// 这份文本是**送审和自救的唯一凭据**：用户拿着它去找人看，或者自己照着重放。
/// 所以它必须能在自检里按段落断言，而不是"点一下按钮看看写出来什么"。
///
/// ## 它必须说的三件事
///
/// 1. **发生了什么**——原始错误文案，不翻译；
/// 2. **东西在哪儿**——被搬走的文件现在叫什么、多大。没有这一条，用户
///    就只剩"我的素材没了"这一个结论；
/// 3. **现在是什么状态**——新库建出来了没有、结构对不对。这一条是为了
///    区分"新库也坏了"和"新库好用，只是空了"。
struct LibraryDiagnostics {

    /// 库里现在有什么。从**新库**读——读不到就照实说读不到。
    struct CurrentState {
        var structure: LibraryStructure?
        var journalMode: String?
        var fileSizes: (main: Int, wal: Int, shm: Int)?
        var assetCount: Int?
        var boardCount: Int?
        var elementCount: Int?
        /// 读新库时出的错。非空时上面几项一定为空。
        var failure: String?
    }

    static func render(
        directory: URL,
        quarantine: LibraryQuarantine,
        current: CurrentState,
        appVersion: String,
        systemVersion: String,
        now: Date = Date()
    ) -> String {
        var lines: [String] = []
        lines.append("Pin 素材库诊断")
        lines.append("生成时间：\(dateFormatter.string(from: now))")
        lines.append("应用版本：\(appVersion)")
        lines.append("系统版本：\(systemVersion)")
        lines.append("数据目录：\(directory.path)")
        lines.append("")

        lines.append("【发生了什么】")
        lines.append("原来的库打不开：\(quarantine.reason)")
        lines.append("发生时间：\(dateFormatter.string(from: quarantine.occurredAt))")
        lines.append("")

        lines.append("【原来的库在哪儿】")
        lines.append("已改名备份，**没有被删除**：")
        lines.append("  \(quarantine.destination.path)")
        lines.append("  主文件原大小：\(quarantine.byteCount) 字节")
        for companion in quarantine.movedCompanions {
            lines.append("  一并搬走：\(companion)")
        }
        lines.append("")

        lines.append("【现在的库】")
        if let failure = current.failure {
            // 读不到就照实说。写成一段空白的话，看报告的人会以为"新库是空的"——
            // 而"读不出来"和"里面没有东西"要采取的行动完全不同。
            lines.append("读不出来：\(failure)")
        } else {
            if let structure = current.structure {
                lines.append("库版本：user_version = \(structure.version)")
                lines.append(
                    "表（\(structure.tables.count) 张）："
                    + structure.tables.sorted().joined(separator: ", ")
                )
            }
            if let journalMode = current.journalMode {
                lines.append("journal 模式：\(journalMode)")
            }
            if let sizes = current.fileSizes {
                lines.append("\(LibraryDatabase.fileName)：\(sizes.main) 字节")
                lines.append("\(LibraryDatabase.fileName)-wal：\(sizes.wal) 字节")
                lines.append("\(LibraryDatabase.fileName)-shm：\(sizes.shm) 字节")
            }
            lines.append("画布：\(current.boardCount.map(String.init) ?? "未读到") 块")
            lines.append("元素：\(current.elementCount.map(String.init) ?? "未读到") 个")
            lines.append("素材：\(current.assetCount.map(String.init) ?? "未读到") 条")
        }
        lines.append("")

        lines.append("【说明】")
        lines.append("素材的原始图片文件不在库里，它们还在 assets/ 目录下，**没有被删除**。")
        lines.append("这份诊断和上面那个备份文件是排查问题的全部材料，可以一起发出去。")
        return lines.joined(separator: "\n")
    }

    /// 读一眼**新库**现在是什么样。
    ///
    /// 单独一个函数、而不是让调用方自己拼：这段读取和 `--library-report`
    /// 读的是同一批事实，两处各写一遍的话，将来加了表只改一处，
    /// 另一处就开始"报告里没有它"——而报告最怕的就是悄悄少一段。
    ///
    /// **读失败不是异常，是这份诊断要报的内容之一**（`CurrentState.failure`）：
    /// 建空库这一步本身也可能失败（磁盘满、目录只读），那种情况下
    /// "新库也坏了"和"新库好用只是空了"要能分开。
    static func readCurrentState(at directory: URL) async -> CurrentState {
        var state = CurrentState()
        do {
            let database = try LibraryDatabase.open(at: directory)
            let scenes = SceneStore(database: database)
            state.structure = try await database.structure()
            state.journalMode = try await database.journalMode()
            state.fileSizes = database.fileSizes()
            state.assetCount = try await AssetStore(database: database, root: directory).allAssets().count
            state.boardCount = try await scenes.boardCount()
            state.elementCount = try await scenes.elementCount()
        } catch {
            state.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        return state
    }

    /// 固定格式 + 本地时区。报告里的时间要能和用户在访达里看到的文件时间对上，
    /// 所以这里和 `LibraryRecovery.timestamp` 一样用本地时区；
    /// 而**格式**固定（不用本地化短日期），否则不同区域的机器上读法不一致。
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
