import Foundation
import GRDB

/// 库结构。**逐条 `registerMigration`，一条也不合并**。
///
/// ## 为什么每次改结构都必须是新的一条
///
/// 因为已经有人跑过旧版本了。把 v1 改了字面量再发布，第二次启动时迁移器看到
/// "v1 已经跑过"就直接跳过——库停在一个**既不是旧版也不是新版**的结构上，
/// 而它报不出一句错。这类问题的形态是"只有开发机的库是坏的"，用户那边是好的：
/// 最难复现的一种。
///
/// 本轮只有 v1（空库开始），所以"加法"这条规矩现在只能靠这段话立着。
/// 判断标准很简单：**已经有人跑过的迁移，一个字都不许改**。
enum Schema {

    /// 当前的库版本号。写进 `PRAGMA user_version`，`--library-report` 会打印它。
    static let version = 1

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // 发布后不改：`Schema.v1` 一个字都不能动，改结构一律加 `v2`。
        migrator.registerMigration("v1") { db in
            try v1(db)
        }

        return migrator
    }

    /// v1：画布、素材、元素三张表。
    ///
    /// ## 三张表的关系
    ///
    /// ```text
    /// board ──< element >── asset
    /// ```
    ///
    /// `element` 在中间，两边都是**引用**：
    ///
    /// - 元素只引用素材，不拥有它。同一张素材可以在画布上出现多次（路线图 §5
    ///   必测场景），所以这里天然是多对一。移除元素**不删素材**——那条规则在
    ///   这一段 schema 里的体现就是"删 element 不动 asset"。
    /// - 元素属于一块画布。删画布连带删元素（`ON DELETE CASCADE`）：元素离开
    ///   画布之后没有任何意义，留着只会让下一次恢复读到一批孤儿。
    ///
    /// ## 素材删除为什么是 RESTRICT
    ///
    /// 素材还挂在某个元素上时，删它会让那个元素变成悬空引用——画布上留一个
    /// 永远空着的框。本轮不开放素材删除（§8），但**约束现在就要在**：等删素材的
    /// 功能做出来时再加约束，就得先清理历史数据里已经产生的悬空引用。
    static func v1(_ db: Database) throws {
        // MARK: board

        try db.create(table: "board") { t in
            t.column("id", .text).notNull().primaryKey()
            t.column("name", .text).notNull()
            // 时间一律存 Unix 秒（REAL）。不用 ISO 字符串：那是**两个**真相
            // （格式与时区），而排序、比较都只要一个数。诊断时自己转一下就是了。
            t.column("created_at", .double).notNull()
            // 画布顺序。**不是** created_at 的排序：用户能拖动排序（后续），
            // 那时时间戳给不出想要的结果。
            t.column("sort", .integer).notNull()
        }

        // MARK: asset
        //
        // **相机与选中一律没有列**：两者都不持久化（§7 第 6、7 条）。
        // 不留 `board_view` 这类表——留了下一轮就会有人顺手把相机写进去。

        try db.create(table: "asset") { t in
            t.column("id", .text).notNull().primaryKey()
            /// 导入时用户看到的文件名。**只用于显示**：磁盘上的名字是 UUID，
            /// 因为同一个文件名可以有不同的内容（重复导入不合并，§7 第 4 条）。
            t.column("original_filename", .text).notNull()
            /// 相对数据目录的路径（`assets/ab/<uuid>.png`），**不存绝对路径**。
            /// 存绝对路径的话，用户把库搬到另一台机器、或者 macOS 换了
            /// Application Support 的位置，整库素材一起失联。
            t.column("relative_path", .text).notNull()
            t.column("byte_count", .integer).notNull()
            /// 原字节的 SHA-256（十六进制小写）。本轮**不做去重**（§7 第 4 条），
            /// 存它是为了"这个素材是哪一份字节"可核对。
            t.column("content_hash", .text).notNull()
            /// **方向已校正**的像素尺寸——与 `ImageMetadata.pixelSize` 同一口径。
            /// 存摆正后的值，是因为画布上摆的是摆正之后的图；存原始尺寸的话，
            /// 每次恢复都要重新读一遍 EXIF 才知道该按哪个比例摆。
            t.column("pixel_width", .integer).notNull()
            t.column("pixel_height", .integer).notNull()
            /// 文件里读到的 EXIF 方向值（1 = 不旋转；没有 EXIF 时也记 1）。
            /// 尺寸已经摆正，这里留的是**原始值**：方向解析错了的时候，
            /// 只有它能把"文件里写的是什么"和"我们算成了什么"对上。
            t.column("exif_orientation", .integer).notNull()
            /// 素材种类。本轮只有 `image`；字体素材源（Pin Web 已有）以后会用到，
            /// 所以是一列而不是隐含的。
            t.column("kind", .text).notNull()
            /// 从哪来的（`import` / `paste` / `drag` / `web`）。C1 只写 `import`，
            /// C2 会写另外几个——**现在就在 schema 里**，否则 C2 又要迁移一次。
            t.column("origin", .text).notNull()
            t.column("added_at", .double).notNull()
        }
        // 面板按 `added_at DESC` 排（§3.4）。加索引是因为素材面板每次滚动都要排，
        // 而它是"几百条素材"这个场景里第一个会被点到的热点。
        try db.create(index: "asset_added_at", on: "asset", columns: ["added_at"])

        // MARK: element

        try db.create(table: "element") { t in
            t.column("id", .text).notNull().primaryKey()
            t.column("board_id", .text).notNull()
                .references("board", onDelete: .cascade)
            t.column("asset_id", .text).notNull()
                .references("asset", onDelete: .restrict)
            // 外框，**世界坐标**（与 `CanvasElement.frame` 同口径）。
            // 拆成四列而不是一个字符串：将来"找视口内的元素"要按范围查。
            t.column("x", .double).notNull()
            t.column("y", .double).notNull()
            t.column("w", .double).notNull()
            t.column("h", .double).notNull()
            /// 绘制顺序，小的在下（与 `CanvasElement.order` 同名同义）。
            t.column("z", .integer).notNull()
        }
        // 恢复一块画布 = 按 (board_id, z) 取一遍。没有它就得全表扫 + 排序。
        try db.create(index: "element_board_z", on: "element", columns: ["board_id", "z"])
        // `asset_id` 上的索引：删素材那天的 RESTRICT 检查要走它，
        // 而那时库里可能有几千个元素——没有索引的话是每次全表扫。
        try db.create(index: "element_asset", on: "element", columns: ["asset_id"])

        // GRDB 只把自己的迁移记录写进 `grdb_migrations`，**不动** `user_version`。
        // 这里显式写上，`user_version` 才会跟着 `Schema.version` 走
        // （`--library-report` 与自检都读它）。本迁移发布后，这一行和其余部分
        // 一样不可再改——新版本要由**新的迁移**去写新的号。
        try db.execute(sql: "PRAGMA user_version = \(Schema.version)")
    }
}
