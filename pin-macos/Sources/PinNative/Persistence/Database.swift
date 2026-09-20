import Foundation
import GRDB

/// 库打不开、或迁移失败。
///
/// ## 为什么单独一个错误类型，而不是把 GRDB 的错直接透出去
///
/// 因为这个错误的**去处是界面**：`WorkspaceModel.storageError` 会把它显示出来。
/// GRDB 的 `DatabaseError` 是英文的、带 SQL 片段的，用户看了不知道该怎么办；
/// 而"打不开素材库"这句话能让人做出下一步动作（看磁盘满没满、权限对不对）。
///
/// 里面仍然**带上原始原因和路径**：文案是给用户的，路径和原因是给出诊断的人
/// （`--library-report` 与送审报告都要打印它）。C2 的"损坏库导出诊断"直接用它。
enum DatabaseOpenError: Error, LocalizedError, Equatable {
    /// 数据目录建不出来（磁盘满、权限、路径被一个文件占着）。
    case directoryUnavailable(path: String, reason: String)
    /// 库文件打不开，或者不是 SQLite 库。
    /// `code` 是 SQLite 的主结果码，`failureKind` 靠它区分"坏了"和"暂时打不开"。
    case openFailed(path: String, reason: String, code: Int32?)
    /// 建表/迁移失败。语义上比"打不开"重：库是好的，但结构升不上去。
    case migrationFailed(path: String, reason: String, code: Int32?)

    /// 这次打不开属于哪一类（C2 返修第 1 条）。
    ///
    /// **判据只能是 SQLite 自己的结果码，不能是我们的猜测。** 因为分错的代价
    /// 两个方向完全不对称：
    ///
    /// - 把"暂时打不开"当成坏库 → 库被改名挪走、换上一个空库。**不可逆**，
    ///   而且用户看到空画布的第一反应是"我的素材被删了"（那一轮 C2 §5 明令
    ///   不许静默覆盖的正是这件事）；
    /// - 把真坏库当成"暂时打不开" → 只是多报一次错，人和数据都还在。
    ///
    /// 所以规则是**只有拿到确凿的损坏码才隔离**，其余一律按"打不开"报出去。
    enum FailureKind: Equatable {
        /// 文件确实不是一个能用的库（`SQLITE_CORRUPT` / `SQLITE_NOTADB`）。
        /// **唯一**该改名隔离的一种。
        case corruptLibrary
        /// 暂时打不开：忙锁、临时 I/O、目录还建不出来。库多半是好的，
        /// 等另一个实例退出、或者磁盘腾出空间就能开——自动重试有意义，
        /// 改名备份则是有害的。
        case temporarilyUnavailable
        /// 库是好的，但它升不到当前结构（迁移里的 SQL 出错、约束冲突）。
        /// 重试无用；**更不能隔离**——那会拿一个好库换一个空库，
        /// 正是 `LibraryDatabase.open` 里"迁移失败不建空库、不删文件"那句
        /// 要挡住的事（`LibraryRecovery` 早先对所有 `DatabaseOpenError`
        /// 一律隔离，等于把库里那层保护又绕过去了）。
        case schemaUpgradeFailed
    }

    /// SQLite 的两个"这个文件不是一个能用的库"码。
    ///
    /// 名字用 GRDB 的常量而不是 `11` / `26`：GRDB 的类型只允许出现在本文件里
    /// （枚举带的是 `Int32`），但**认出这两个码的判断**必须写得一眼可读——
    /// 它是"改不改名挪走用户的库"的唯一判据。
    private static let corruptionCodes: Set<Int32> = [
        DatabaseError.SQLITE_CORRUPT.rawValue,   // 库文件本身坏了
        DatabaseError.SQLITE_NOTADB.rawValue,    // 根本不是数据库，或文件头被写坏
    ]

    var failureKind: FailureKind {
        // 损坏码出现在**任何一步**都是同一个结论：这份文件不是一个能用的库。
        // 打开时才发现（NOTADB）和迁移读到一半才发现（CORRUPT）没有区别。
        if let code = sqliteCode, Self.corruptionCodes.contains(code) { return .corruptLibrary }
        switch self {
        case .directoryUnavailable, .openFailed: return .temporarilyUnavailable
        case .migrationFailed: return .schemaUpgradeFailed
        }
    }

    /// 值得再试一次吗（启动时的自动重试与界面上的「重试」按钮）。
    var isRetryable: Bool { failureKind == .temporarilyUnavailable }

    /// 该不该把库改名备份走。**只有确凿的损坏码**，理由见 `FailureKind`。
    var shouldQuarantine: Bool { failureKind == .corruptLibrary }

    /// SQLite 给回来的主结果码，没有就是 `nil`。诊断报告要用。
    var sqliteCode: Int32? {
        switch self {
        case .directoryUnavailable: nil
        case .openFailed(_, _, let code), .migrationFailed(_, _, let code): code
        }
    }

    var errorDescription: String? {
        switch self {
        case .directoryUnavailable(_, let reason):
            "建不了数据目录：\(reason)"
        case .openFailed(let path, let reason, _):
            "打不开素材库：\(reason)（\(path)）"
        case .migrationFailed(let path, let reason, _):
            "素材库结构升级失败：\(reason)（\(path)）"
        }
    }

    /// 出错的路径。诊断报告要用。
    var path: String {
        switch self {
        case .directoryUnavailable(let path, _),
             .openFailed(let path, _, _),
             .migrationFailed(let path, _, _):
            path
        }
    }
}

/// 库结构的自述：版本号、表、索引、列。
///
/// 存在的理由有一句话就够了：**"结构对不对"不能靠记忆**。
///
/// - `--library-report`（§3.7）要打印它。用户报"素材打不开"时，第一件要确认的
///   事就是那份库到底有没有那几张表、停在哪个版本；
/// - 自检直接断言它。断言里写 `SELECT ... FROM sqlite_master` 的话，SQL 会漏到
///   `Persistence/` 外面去（那里不许 `import GRDB`），而"库里有什么表"这件事
///   本来就该由库自己回答。
struct LibraryStructure: Sendable, Equatable {
    /// `PRAGMA user_version`，与 `Schema.version` 是同一个口径。
    var version: Int
    var tables: [String]
    var indexes: [String]
    /// 表名 → 列名（按 SQLite 给回来的顺序）。
    var columns: [String: [String]]
}

/// 库文件的连接与迁移。
///
/// ## 类型名为什么是 `LibraryDatabase` 而不是 `Database`
///
/// 因为 GRDB 自己有一个 `Database`（一次连接/事务的句柄，所有 `db.execute` 的
/// 接收者）。同名的话，本模块里写的 `db: Database` 会解析成本类型而不是 GRDB 那个
/// ——**编译错误会出现在每一个写 SQL 的地方**，而那句 `into db: Database` 读起来
/// 完全正常。名字撞一次，之后每个人都得先想一秒"这是哪个 Database"。
///
/// ## 为什么是 `DatabasePool` 而不是 `DatabaseQueue`
///
/// 路线图 §2.4 的主线程预算靠两件事守住，其中一件是**读不挡写**。`DatabaseQueue`
/// 是单连接串行的：后台正在写一条拖动结果时，主线程的读要排队等它——而那个读
/// 恰好发生在切画布、刷面板这些"用户正盯着看"的时刻。`DatabasePool` 走 WAL，
/// 多读一写互不阻塞，代价只是多几个文件（`-wal` / `-shm`，C2 的损坏处理要连它们
/// 一起改名，所以它们的存在是**约定**的一部分）。
///
/// ## 线程口径（§3.1）
///
/// 「读在主线程、写走 writer 队列」指的是**谁在等**，不是**在哪跑**：
///
/// - 启动恢复那一次读，读完之后主线程只读内存里的 `LibrarySnapshot`，
///   之后再也不碰库（见 `LibrarySnapshot`）；
/// - 所有 `async` 读写都**不在调用方的 actor 上跑**：GRDB 的异步接口把闭包丢到
///   自己的队列池里执行，这正是我们要的——主线程发起、主线程不等。
///
/// 反过来写成同步 `try pool.read { }` 的话，它会**阻塞当前线程**直到拿到连接。
/// 那正是主线程预算最怕的一种写法，而且它读起来没有任何"我在做 I/O"的暗示。
struct LibraryDatabase: Sendable {

    /// 库文件名。C2 的损坏备份会用到它（连同 `-wal` / `-shm`）。
    static let fileName = "pin.sqlite"

    let fileURL: URL
    let pool: DatabasePool

    /// 打开（必要时创建）库，并升级到最新结构。
    ///
    /// - Parameter directory: 数据目录。**传入而不是自己拼**：目录的唯一来源是
    ///   `AppEnvironment`，这里再拼一次就有了两处真相（而两处真相的典型症状是
    ///   "写进了一个没人读的目录"）。
    static func open(at directory: URL, fileManager: FileManager = .default) throws -> LibraryDatabase {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DatabaseOpenError.directoryUnavailable(
                path: directory.path,
                reason: error.localizedDescription
            )
        }
        let fileURL = directory.appendingPathComponent(fileName)

        var configuration = Configuration()
        // 库文件按 profile 分开（`AppEnvironment`），同一个库不会被两个进程同时写；
        // 但**不假设**这一点：默认的 `.immediateError` 会让"另一个实例恰好也在跑"
        // 直接变成打不开，而那时用户看到的是"素材库坏了"，不是"另一个窗口在用"。
        configuration.busyMode = .timeout(5)
        // 外键约束开着（GRDB 默认就是开，这里写出来是因为**它必须是真的**：
        // `element.asset_id` 指向不存在的素材时，宁可插入失败也不要留下悬空引用，
        // 而"素材还被元素引用着就不许删"这条规则正是靠它挡住的）。
        configuration.foreignKeysEnabled = true

        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: fileURL.path, configuration: configuration)
        } catch {
            throw DatabaseOpenError.openFailed(
                path: fileURL.path,
                reason: error.localizedDescription,
                // GRDB 的错在这里**只取一个码**就丢掉类型：往上走的
                // `DatabaseOpenError` 要能脱离 GRDB 被界面和自检使用，
                // 而"是不是坏库"这件事只取决于这个码。
                code: (error as? DatabaseError)?.resultCode.rawValue
            )
        }

        do {
            try Schema.migrator.migrate(pool)
        } catch {
            // 迁移失败**不建空库、不删文件**：那会把用户唯一的一份数据换成一个
            // 看起来正常的空库。C2 的完整形态是连 -wal/-shm 一起改名备份再建新库，
            // 本轮的做法是**停下来报错**——库还在，人能去救。
            //
            // 注意这里连码一起带走：迁移读到一半发现 `SQLITE_CORRUPT`，与迁移的
            // SQL 写错了，是两件完全不同的事（前者才该隔离）。
            throw DatabaseOpenError.migrationFailed(
                path: fileURL.path,
                reason: error.localizedDescription,
                code: (error as? DatabaseError)?.resultCode.rawValue
            )
        }

        return LibraryDatabase(fileURL: fileURL, pool: pool)
    }

    // MARK: - 读

    /// 一次异步读。**不在调用方的 actor 上跑**（见类型说明）。
    func read<T: Sendable>(_ value: @Sendable (GRDB.Database) throws -> T) async throws -> T {
        try await pool.read(value)
    }

    /// 一次异步写，在一个事务里。
    func write<T: Sendable>(_ updates: @Sendable (GRDB.Database) throws -> T) async throws -> T {
        try await pool.write(updates)
    }

    // MARK: - 诊断

    /// 库文件的字节数（含 `-wal` / `-shm`）。`--library-report` 要用。
    ///
    /// 三个文件一起算：只说主文件的大小会低估（WAL 里可能还压着一批没合并的写入），
    /// 而这是一个"这份数据占了多少磁盘"的问题。
    func fileSizes(fileManager: FileManager = .default) -> (main: Int, wal: Int, shm: Int) {
        func size(_ suffix: String) -> Int {
            let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path + suffix)
            return (attributes?[.size] as? Int) ?? 0
        }
        return (size(""), size("-wal"), size("-shm"))
    }

    /// 当前的 journal 模式。断言用它确认 WAL 真的开着——**实测而不是按记忆**：
    /// "用的是 DatabasePool 所以肯定是 WAL"是一句推论，而推错了的表现是
    /// "读会挡写"，那在空库上完全看不出来。
    func journalMode() async throws -> String {
        try await read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
        }
    }

    /// 读一遍自己的结构（表、索引、列、版本号）。见 `LibraryStructure`。
    ///
    /// 内部的表（`sqlite_%` 与 GRDB 自己那张迁移记录表）一并读出来而不是过滤掉：
    /// 报告里少一行"其实有这张表"比多一行无害得多，而过滤规则一旦写在这里，
    /// 就没人知道被滤掉的是什么了。
    func structure() async throws -> LibraryStructure {
        try await read { db in
            let tables = try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                    ORDER BY name
                    """
            )
            let indexes = try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'index' AND name NOT LIKE 'sqlite_%'
                    ORDER BY name
                    """
            )
            var columns: [String: [String]] = [:]
            for table in tables {
                // 表名来自 `sqlite_master` 而不是调用方，所以这里拼进 SQL 的
                // 是库自己报出来的标识符（`PRAGMA` 也不接受绑定参数）。
                columns[table] = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                    .map { $0["name"] ?? "" }
            }
            return LibraryStructure(
                version: try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0,
                tables: tables,
                indexes: indexes,
                columns: columns
            )
        }
    }
}
