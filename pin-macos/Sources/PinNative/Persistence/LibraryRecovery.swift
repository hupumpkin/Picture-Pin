import Foundation

/// 一次"库打不开、被改名让路"的记录（C2 §4 第 4 条）。
///
/// 它存在的唯一理由是**让这件事说出来**：§5 明确要求"损坏数据保留备份与诊断，
/// 不静默覆盖"。静默的表现是最坏的一种——用户看到的是一个空库，会以为自己的
/// 素材被删了；而他真正该做的事（去备份目录里把文件捞出来）没有任何入口。
struct LibraryQuarantine: Equatable {

    /// 原来的库文件名，例如 `pin.sqlite`。文案里要出现它。
    let originalName: String

    /// 改名后的落点。**用户要能照着这个路径自己去找回文件**，
    /// 所以它是完整路径，不是相对路径。
    let destination: URL

    /// 一起被搬走的同伴（`-wal` / `-shm`）。
    ///
    /// 必须一起搬：只搬主文件的话，新库建出来时 SQLite 会在原位置发现一份
    /// **属于旧库的 WAL**并试图回放它——那是最糟的结果，坏数据被灌进新库里。
    let movedCompanions: [String]

    /// 原始错误的文案，原样带过来给用户看。
    ///
    /// 不重新翻译一遍：`DatabaseOpenError` 那一层已经分好了"建不了目录 /
    /// 打不开 / 升不上去"三种说法，而**它们的处理方式不同**——用户需要看到
    /// 是哪一种。这里再包一层"素材库出错了"只会把能用的信息盖掉。
    let reason: String

    /// 被隔离的主文件字节数。诊断报告里要有：一个 0 字节的库和
    /// 一个 80 MB 的库，"坏了"的含义完全不同。
    let byteCount: Int

    let occurredAt: Date
}

/// "打不开就改名让路"这条完整形态（C2 §4 第 4 条）。
///
/// ## 为什么不是 `LibraryDatabase.open` 自己做的事
///
/// 改名是一件**不可逆、且用户必须知情**的事。写成 `open` 的副作用的话，
/// 任何一个调用点（快照、报告、自检）打开一个坏库都会顺手把它挪走——
/// 而其中有些调用点只是想读一眼。所以它单独是一个动作，只在**用户看得见
/// 的那条启动路径**上被调用（`WorkspaceModel.prepareStorage`），
/// 并且把发生的事原样返回给界面。
enum LibraryRecovery {

    /// 打不开就改名备份、再建一个空库——**但只在确认库真的坏了的时候**。
    ///
    /// - Returns: 打开的库，以及这次有没有隔离过东西（`nil` = 一切正常）。
    /// - Throws: 三种情况会抛：**目录建不出来**、**暂时打不开**（忙锁、临时 I/O）、
    ///   以及**结构升不上去**。这三种都不改名、不重建：前两种过一会儿可能就好了，
    ///   第三种库里装着的是好数据。改名或重建本身失败时也抛——那时宁可停下报错，
    ///   也不能带着一个半截状态继续跑。
    static func open(
        at directory: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> (database: LibraryDatabase, quarantine: LibraryQuarantine?) {
        do {
            return (try LibraryDatabase.open(at: directory), nil)
        } catch let error as DatabaseOpenError {
            // **隔离的判据只有一条：拿到了确凿的损坏码**（`FailureKind`）。
            //
            // 早先这里是"是 `DatabaseOpenError` 就隔离"，于是忙锁、临时 I/O、
            // 甚至"迁移失败"都会把库改名挪走、换上一个空库——而改名不可逆，
            // 用户看到空画布的第一反应是"我的素材被删了"。更糟的是迁移那条：
            // `LibraryDatabase.open` 特意写了"不建空库、不删文件"，这层却把
            // 它绕过去了。宁可少隔离一次（人还能自己去救），也不能拿好库换空库。
            guard error.shouldQuarantine else { throw error }
            let quarantine = try quarantine(in: directory, reason: error, fileManager: fileManager, now: now)
            return (try LibraryDatabase.open(at: directory), quarantine)
        }
    }

    /// 把坏库连同同伴改名搬走。返回搬了什么。
    ///
    /// 先搬主文件：它搬不动的话（权限、被别的进程占着），**立刻抛出去**，
    /// 一个字节都不动。反过来先搬 `-wal` 的话，主文件搬不动时库里就剩下
    /// 一个光秃秃的主文件——比搬之前更糟。
    private static func quarantine(
        in directory: URL,
        reason: DatabaseOpenError,
        fileManager: FileManager,
        now: Date
    ) throws -> LibraryQuarantine {
        let stamp = timestamp(now)
        let main = directory.appendingPathComponent(LibraryDatabase.fileName)
        let byteCount = (try? fileManager.attributesOfItem(atPath: main.path))?[.size] as? Int ?? 0

        // **组名先定，三个文件共用一份。** 见 `uniqueGroupName`。
        let group = uniqueGroupName(stamp: stamp, in: directory, fileManager: fileManager)

        var moved: [String] = []
        var destination = main
        for suffix in ["", "-wal", "-shm"] {
            let source = directory.appendingPathComponent(LibraryDatabase.fileName + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let target = directory.appendingPathComponent(
                "\(LibraryDatabase.fileName).\(group)\(suffix)"
            )
            try fileManager.moveItem(at: source, to: target)
            if moved.isEmpty { destination = target }
            moved.append(source.lastPathComponent)
        }

        return LibraryQuarantine(
            originalName: LibraryDatabase.fileName,
            destination: destination,
            movedCompanions: Array(moved.dropFirst()),
            reason: reason.errorDescription ?? reason.path,
            byteCount: byteCount,
            occurredAt: now
        )
    }

    /// 同一组备份共用的名字：`corrupt-20260918-162233`，同一秒里的第二次是
    /// `corrupt-20260918-162233-2`。
    ///
    /// **先定组名、三个文件共用一份**，而不是每个文件各自去重。各自的判据是
    /// "这个文件名被占了没有"，而三个文件被占的情况可以不同（上一组可能只搬走了
    /// 主库、这一组却有 `-wal`）：同一秒里的两次隔离于是会把一组的成员拆到两个
    /// 不同的名字下。而"哪几个文件该放回一起"正是用户拿着备份去救数据时唯一要
    /// 判断的事——拆散了的那份备份等于没有备份。
    ///
    /// 判据只看主库的落点：主库名没被占，这一组就还是空的。
    ///
    /// 序号加在**组名末尾**，不是加在主库名后面。按主库名去重会得出
    /// `pin.sqlite-2.corrupt-…` 这种名字，读起来像"另一个库"，而它其实只是
    /// 同一份库的第二次备份——用户正是靠名字判断该把哪几个文件放回一起的。
    private static func uniqueGroupName(
        stamp: String,
        in directory: URL,
        fileManager: FileManager
    ) -> String {
        let base = "corrupt-\(stamp)"
        func isTaken(_ name: String) -> Bool {
            fileManager.fileExists(
                atPath: directory.appendingPathComponent("\(LibraryDatabase.fileName).\(name)").path
            )
        }
        for index in 1...1000 {
            let name = index == 1 ? base : "\(base)-\(index)"
            if !isTaken(name) { return name }
        }
        // 同一秒里隔离一千次（只可能是脚本在压测）。不再往下数：加一段随机尾巴
        // 而不是继续数数字，这样**一定不会撞名**——撞名的代价是覆盖掉上一份备份，
        // 那是唯一一份数据。
        return "\(base)-\(UUID().uuidString.prefix(8))"
    }

    /// `20260918-162233`。**不用 `DateFormatter` 的本地化格式**：
    /// 文件名要能排序、能一眼读出年月日，而本地化的短日期在不同区域设置下
    /// 会变成 `18/9/26` 这种既不能排序也认不出顺序的样子。
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
