import CoreGraphics
import CryptoKit
import Foundation
import GRDB

/// 素材库里的一条记录。
///
/// ## 为什么它不是 `PersistableRecord`
///
/// 因为 GRDB 只允许出现在 `Persistence/` 一处（`Package.swift` 里写死的规矩）。
/// 让这个类型变成 GRDB 记录，`Assets/`、`Materials/`、界面都会被迫 `import GRDB`
/// ——那时"换掉数据库"就不再是改一个目录的事。映射写在 `AssetStore` 里，
/// 是几行重复，换来的是一条能守住的边界。
///
/// 它同时是**渲染路径看的那个类型**：`relativePath` 加上数据目录就是文件的
/// 位置，中间不再查库。
struct AssetRecord: Equatable, Sendable, Identifiable {

    /// 素材从哪来。C1 只写 `.fileImport`；其余几种 C2 才产生。
    ///
    /// **现在就定全**（而不是只写 `import`）：这个值要进库，而给它加一种取值
    /// 意味着一次迁移。四种来源在一次迁移里全定完，C2 就只是写不同的值。
    enum Origin: String, Equatable, Sendable, CaseIterable {
        /// 文件选择器导入。
        case fileImport = "import"
        /// 剪贴板里的位图数据（落成 PNG，§7 第 3 条）。
        case paste
        /// 从访达拖进来。
        case dragIn = "drag"
        /// 网页采集（路线图 §6 的后续阶段）。
        case web
    }

    /// 素材种类。本轮只有图片；字体素材源（Pin Web 已有）以后会用到。
    enum Kind: String, Equatable, Sendable {
        case image
    }

    let id: AssetID
    /// 导入时用户看到的文件名。**只用于显示**——磁盘上的名字是 UUID。
    var originalFilename: String
    /// 相对数据目录的路径，例如 `assets/ab/<uuid>.png`。**不是绝对路径**。
    var relativePath: String
    var byteCount: Int
    /// 原字节的 SHA-256（十六进制小写）。本轮不做去重（§7 第 4 条）。
    var contentHash: String
    /// **摆正之后**的像素尺寸。
    var pixelSize: CGSize
    /// 文件里写着的 EXIF 方向值。
    var exifOrientation: Int
    var kind: Kind
    var origin: Origin
    var addedAt: Date

    /// 文件的绝对位置。
    ///
    /// `root` 是数据目录。**每次算，不存**——存绝对路径的库搬一次机器就全失联
    /// （见 `Schema.v1` 里那一列的说法）。
    func fileURL(in root: URL) -> URL {
        root.appendingPathComponent(relativePath)
    }
}

/// 素材的落盘与读写。**素材文件的唯一入口。**
///
/// ## 为什么复制原字节，不转码
///
/// 转码（哪怕只是"顺手"重存一遍 PNG）会改掉三样东西：格式、尺寸、EXIF 方向。
/// 而这三样恰好是路线图 §5 的必测项——**测的是解码链路，不是我们的转码器**。
/// 还有一条更实际的：转码是**不可逆**的。用户从 AE 导出的一张 16bit PNG 被我们
/// 存成 8bit 之后，原图就只剩他硬盘上那一份了，而我们已经声称"导入完成"。
///
/// ## 为什么磁盘文件名是 UUID
///
/// 因为**重复导入不合并**（§7 第 4 条）：同名不同内容的两份素材必须能同时存在。
/// 用原名当文件名的话，第二次导入要么覆盖第一次（丢数据），要么加后缀
/// （`图-1.png`、`图-2.png`，而"哪份是哪次导入的"从此无处可查）。
struct AssetStore: Sendable {

    /// 一次复制的分块大小。256 KB 是个折中：够大所以系统调用不多，
    /// 够小所以一张 200 MP 的图也不会把内存顶起来。
    static let copyChunkBytes = 256 * 1024

    let database: LibraryDatabase
    /// 数据目录。素材文件的落点由它 + `relativePath` 决定。
    let root: URL

    // MARK: - 导入

    /// 把一份文件收进素材库：复制原字节 → 流式哈希 → 读属性 → 入库。
    ///
    /// **任一步失败都不留半成品**：落过盘的文件会被删掉，空出来的分桶目录
    /// 一并清掉（§5 失败不产生悬空素材）。这一条比它看起来重要——导入失败之后
    /// 留下一个没人引用的文件，用户看不到它，它也不会被清理，只会一直占着磁盘。
    ///
    /// ## 为什么这个方法是 `@MainActor` 而复制不是
    ///
    /// 它要做三件需要主 actor 的事：改界面上的导入进度、调 `prober`（`@MainActor`
    /// 协议）、以及**串行化**——同一份素材被导入两次时，两条流水线不能交错。
    /// 但它自己几乎不干活：分块复制与哈希在 `copyAndHash` 里，那是
    /// `nonisolated async`，跑在全局执行器上（与 `SyntheticImageProvider.generate`
    /// 同一个手法）。一张 100 MB 的 TIFF 复制一秒钟，那一秒**不能**在主线程上。
    ///
    /// - Returns: 入库的那条记录。
    /// - Throws: `AssetStore.ImportError`。
    @MainActor
    func ingest(
        from sourceURL: URL,
        origin: AssetRecord.Origin = .fileImport,
        using prober: any ImageFileProbing,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) async throws -> AssetRecord {
        let id = AssetID()
        // 扩展名原样保留（只做小写化）：解码判定交给 ImageIO，我们不做格式白名单
        // （§7 第 5 条），所以这个后缀**只影响 Finder 里的观感**。小写化是为了
        // 大小写敏感的文件系统上不会出现 `A.PNG` 与 `a.png` 两个不同的名字。
        let ext = sourceURL.pathExtension.lowercased()
        let relativePath = Self.relativePath(for: id, extension: ext)
        let destination = root.appendingPathComponent(relativePath)

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw ImportError.cannotPrepareDestination(error.localizedDescription)
        }

        // 复制与哈希**一次读完**：分两遍意味着同一份字节从磁盘上读两次，
        // 而导入一张 100 MB 的 TIFF 时，那第二遍是白等的。
        let byteCount: Int
        let hash: String
        do {
            (byteCount, hash) = try await Self.copyAndHash(from: sourceURL, to: destination)
        } catch {
            Self.removePartial(at: destination)
            throw error
        }

        // 落盘之后才读属性：读的是**库里这一份**，不是用户那份。两者本该一致
        // （就是刚复制过去的），但"本该一致"不是证据，而这里读的代价一样。
        guard let facts = await prober.probe(destination) else {
            Self.removePartial(at: destination)
            throw ImportError.notAnImage
        }

        let record = AssetRecord(
            id: id,
            originalFilename: sourceURL.lastPathComponent,
            relativePath: relativePath,
            byteCount: byteCount,
            contentHash: hash,
            pixelSize: facts.pixelSize,
            exifOrientation: facts.exifOrientation,
            kind: .image,
            origin: origin,
            addedAt: now
        )

        do {
            try await database.write { db in try Self.insert(record, into: db) }
        } catch {
            // 入库失败也要把文件删掉：否则库里没有它、磁盘上有它，
            // 而这个文件永远不会被任何一次清理扫到。
            Self.removePartial(at: destination)
            throw ImportError.cannotPersist(error.localizedDescription)
        }
        return record
    }

    /// 导入失败的原因。**分得比"失败"细一档**：用户能采取的动作不同。
    enum ImportError: Error, LocalizedError {
        /// 素材落点建不出来（磁盘满、权限）。
        case cannotPrepareDestination(String)
        /// 源文件读不了（被移走、权限、外置卷没挂）。
        case cannotRead(String)
        /// 不是一个能解码的图片。**文案统一**（§3.2）：与 `FileImageProvider` 的
        /// `.failed` 共用同一句，不去猜"是格式不对还是文件坏了"——那是 ImageIO
        /// 的判断，我们照抄结论。
        case notAnImage
        /// 落盘成功但写不进库。
        case cannotPersist(String)

        var errorDescription: String? {
            switch self {
            case .cannotPrepareDestination(let reason): "存不进去：\(reason)"
            case .cannotRead(let reason): "读不了这个文件：\(reason)"
            case .notAnImage: FileImageProvider.unifiedDecodeFailure
            case .cannotPersist(let reason): "记不进素材库：\(reason)"
            }
        }
    }

    // MARK: - 读

    func asset(_ id: AssetID) async throws -> AssetRecord? {
        try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM asset WHERE id = ?", arguments: [id.raw.uuidString])
                .map(Self.record(from:))
        }
    }

    /// 全部素材，新的在前（§3.4 的排序口径：`added_at DESC`）。
    ///
    /// 次序里带 `id` 是因为**同一毫秒导入的两份素材 `added_at` 会相同**
    /// （批量导入走到那一步是必然的）。只按时间排的话，两次查询可能给出不同的
    /// 顺序——面板会在刷新时自己重排一下，而那种抖动看起来像"素材在乱跳"。
    func allAssets() async throws -> [AssetRecord] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM asset ORDER BY added_at DESC, id ASC")
                .map(Self.record(from:))
        }
    }

    func count() async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0
        }
    }

    /// 用编辑器产生的新 SVG 原文替换同一份素材。画布元素仍引用原来的 `AssetID`，
    /// 所以不会产生「编辑后画布上的旧元素断开」的第二套迁移逻辑。
    @MainActor
    func replaceSVG(
        _ id: AssetID,
        with data: Data,
        using prober: any ImageFileProbing
    ) async throws -> AssetRecord {
        guard var record = try await asset(id), record.fileURL(in: root).pathExtension.lowercased() == "svg" else {
            throw EditError.notEditableSVG
        }
        let url = record.fileURL(in: root)
        let oldData: Data
        do { oldData = try Data(contentsOf: url) }
        catch { throw EditError.cannotWrite(error.localizedDescription) }
        do { try data.write(to: url, options: .atomic) }
        catch { throw EditError.cannotWrite(error.localizedDescription) }
        guard let facts = await prober.probe(url) else {
            try? oldData.write(to: url, options: .atomic)
            throw EditError.invalidSVG
        }
        record.byteCount = data.count
        record.contentHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        record.pixelSize = facts.pixelSize
        record.exifOrientation = facts.exifOrientation
        let updated = record
        do {
            try await database.write { db in
                try db.execute(sql: """
                    UPDATE asset SET byte_count = ?, content_hash = ?, pixel_width = ?,
                    pixel_height = ?, exif_orientation = ? WHERE id = ?
                    """, arguments: [
                    updated.byteCount, updated.contentHash, Int(updated.pixelSize.width),
                    Int(updated.pixelSize.height), updated.exifOrientation, updated.id.raw.uuidString,
                ])
            }
        } catch {
            try? oldData.write(to: url, options: .atomic)
            throw EditError.cannotPersist(error.localizedDescription)
        }
        return record
    }

    enum EditError: Error, LocalizedError {
        case notEditableSVG, invalidSVG, cannotWrite(String), cannotPersist(String)
        var errorDescription: String? {
            switch self {
            case .notEditableSVG: "选中的素材不是可编辑的 SVG"
            case .invalidSVG: "编辑结果不是可显示的 SVG"
            case .cannotWrite(let reason): "SVG 写入失败：\(reason)"
            case .cannotPersist(let reason): "SVG 记录更新失败：\(reason)"
            }
        }
    }

    // MARK: - 落点

    /// 素材在库里的相对路径：`assets/<id 前两位>/<id>.<ext>`。
    ///
    /// 分两级是因为**同一个目录下放几十万个文件**在 HFS+/APFS 上都会开始难受
    /// （Finder 打开要等、备份要扫很久）。按 ID 前两位分桶是最省事的分法：
    /// 天然均匀（UUID 是随机的）、不需要计数器、加素材不需要移动已有文件。
    static func relativePath(for id: AssetID, extension ext: String) -> String {
        let name = id.raw.uuidString.lowercased()
        let bucket = String(name.prefix(2))
        let file = ext.isEmpty ? name : "\(name).\(ext)"
        return "assets/\(bucket)/\(file)"
    }

    /// 失败清理：删掉已经落盘的文件，再把因此空出来的分桶目录也删掉。
    ///
    /// 分桶目录不删的话，每一次失败的导入都会留下一个空目录（`assets/ab/`）。
    /// 它们无害（§5 说的是不留悬空**文件**），但"失败不留半成品"这句话
    /// 没有理由不包括目录——而删它只需要顺手一步：目录非空时 `removeItem`
    /// 自己会失败，所以这一步**永远不会误删别人的素材**。
    private static func removePartial(at destination: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: destination)
        try? fileManager.removeItem(at: destination.deletingLastPathComponent())
    }

    // MARK: - 分块复制 + 哈希

    /// 把 `source` 的字节写到 `destination`，同时算 SHA-256。
    ///
    /// 用 `FileHandle` 手写循环而不是 `FileManager.copyItem` + 第二遍读：
    /// 后者要把同一份字节从磁盘读两次。导入是**用户按了按钮在等**的操作，
    /// 白读一遍就是白等一半时间。
    ///
    /// `nonisolated async`：跑在全局执行器上，**不占调用方的主 actor**。
    /// 复制一个 100 MB 的文件是一秒钟的阻塞 I/O，而那期间界面要在转进度条。
    private nonisolated static func copyAndHash(
        from source: URL,
        to destination: URL
    ) async throws -> (Int, String) {
        try Self.copyAndHashSynchronously(from: source, to: destination)
    }

    private nonisolated static func copyAndHashSynchronously(
        from source: URL,
        to destination: URL
    ) throws -> (Int, String) {
        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw ImportError.cannotPrepareDestination(destination.path)
        }

        let reader: FileHandle
        let writer: FileHandle
        do {
            reader = try FileHandle(forReadingFrom: source)
            writer = try FileHandle(forWritingTo: destination)
        } catch {
            // 源文件读不了（被移走、权限、外置卷没挂）。**分两种说法**是因为
            // 用户能做的事不同：前者去 Finder 里看一眼，后者去插上移动硬盘。
            throw ImportError.cannotRead(error.localizedDescription)
        }
        defer { try? reader.close(); try? writer.close() }

        var hasher = SHA256()
        var total = 0
        do {
            while let chunk = try reader.read(upToCount: copyChunkBytes), !chunk.isEmpty {
                try writer.write(contentsOf: chunk)
                hasher.update(data: chunk)
                total += chunk.count
            }
        } catch {
            throw ImportError.cannotRead(error.localizedDescription)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (total, digest)
    }

    // MARK: - 行映射

    private static func insert(_ record: AssetRecord, into db: Database) throws {
        try db.execute(sql: """
            INSERT INTO asset (
                id, original_filename, relative_path, byte_count, content_hash,
                pixel_width, pixel_height, exif_orientation, kind, origin, added_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
            record.id.raw.uuidString,
            record.originalFilename,
            record.relativePath,
            record.byteCount,
            record.contentHash,
            Int(record.pixelSize.width),
            Int(record.pixelSize.height),
            record.exifOrientation,
            record.kind.rawValue,
            record.origin.rawValue,
            record.addedAt.timeIntervalSince1970,
        ])
    }

    /// 行 → 记录。**列名与 Swift 名不同名**，所以映射写在这里、读起来是对照表。
    ///
    /// 认不出来的 `kind` / `origin`（比这个版本新的库）按默认值收下而不是抛错：
    /// 那意味着用户跑过一个更新的版本，此时**宁可显示得不对也不要打不开库**。
    static func record(from row: Row) -> AssetRecord {
        AssetRecord(
            id: AssetID(string: row["id"] ?? "") ?? AssetID(),
            originalFilename: row["original_filename"] ?? "",
            relativePath: row["relative_path"] ?? "",
            byteCount: row["byte_count"] ?? 0,
            contentHash: row["content_hash"] ?? "",
            pixelSize: CGSize(
                width: row["pixel_width"] ?? 0,
                height: row["pixel_height"] ?? 0
            ),
            exifOrientation: row["exif_orientation"] ?? 1,
            kind: AssetRecord.Kind(rawValue: row["kind"] ?? "") ?? .image,
            origin: AssetRecord.Origin(rawValue: row["origin"] ?? "") ?? .fileImport,
            addedAt: Date(timeIntervalSince1970: row["added_at"] ?? 0)
        )
    }
}

/// `AssetFileLocator` 的实现：启动时把 `素材 ID → 相对路径` 装进字典，之后只查内存。
///
/// **不做任何 I/O**，连"文件到底在不在"都不问——那件事由解码路径上的
/// `.missing` 分支回答（见 `ImageProvider.metadata(for:)` 的约定）。
/// 在这里顺手 `fileExists` 一次的话，每次扫描都是一次 `stat`。
@MainActor
final class SnapshotAssetLocator: AssetFileLocator {

    private let root: URL
    private var paths: [AssetID: String]

    init(root: URL, assets: some Collection<AssetRecord> = []) {
        self.root = root
        self.paths = Self.index(assets)
    }

    func fileURL(for asset: AssetID) -> URL? {
        guard let relative = paths[asset] else { return nil }
        return root.appendingPathComponent(relative)
    }

    /// 换一批素材。导入之后要调它——不调的话新素材在**重启之前**一直显示不出来，
    /// 而那种表现（"刚导入的图是空的，重启一下就有了"）最容易被当成缓存问题查半天。
    func replace(with assets: some Collection<AssetRecord>) {
        paths = Self.index(assets)
    }

    /// 加一条。导入是**一条一条**来的，重装整份索引在大库上是白扫一遍。
    func insert(_ asset: AssetRecord) {
        paths[asset.id] = asset.relativePath
    }

    private static func index(_ assets: some Collection<AssetRecord>) -> [AssetID: String] {
        Dictionary(
            assets.map { ($0.id, $0.relativePath) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
