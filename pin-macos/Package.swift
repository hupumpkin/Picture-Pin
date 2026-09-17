// swift-tools-version: 6.2
import PackageDescription

// 采用 SPM 而不是 .xcodeproj：两个 agent 同时改 pbxproj 是合并冲突的重灾区，
// SPM 清单是纯文本、可 diff。App bundle 由 scripts/build-app.sh 组装。
let package = Package(
    name: "PinNative",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "PinNative", targets: ["PinNative"])
    ],
    targets: [
        .executableTarget(
            name: "PinNative",
            path: "Sources/PinNative"
        )
    ]
)
