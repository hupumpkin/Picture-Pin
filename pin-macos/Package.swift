// swift-tools-version: 6.2
import PackageDescription

// 采用 SPM 而不是 .xcodeproj：两个 agent 同时改 pbxproj 是合并冲突的重灾区，
// SPM 清单是纯文本、可 diff。App bundle 由 scripts/build-app.sh 组装。
//
// ## 唯一的第三方依赖：GRDB（批次 C 起）
//
// 路线图 §1 定的是 SQLite + GRDB。**代价要知道**：`swift package resolve` 第一次
// 要联网（之后有 `Package.resolved` 与本地缓存，可离线构建）；`Package.resolved`
// 因此进了交付清单，它是"这份代码配哪一版 GRDB"的唯一凭据。
//
// 为什么不用系统 `libsqlite3` 自己包一层：迁移、事务、并发读、值类型绑定这四件事
// 都要自己踩坑，而它们正好是"数据丢没丢"的那一层。第三方依赖的风险用**锁版本 +
// 只在 Persistence/ 一处使用**来控制——其余模块不 import GRDB。
let package = Package(
    name: "PinNative",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "PinNative", targets: ["PinNative"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .executableTarget(
            name: "PinNative",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/PinNative"
        )
    ]
)
