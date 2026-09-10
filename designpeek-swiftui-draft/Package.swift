// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DesignPeekDraft",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DesignPeekDraft", targets: ["DesignPeekDraft"])
    ],
    targets: [
        .executableTarget(
            name: "DesignPeekDraft",
            path: "Sources/DesignPeekDraft"
        )
    ]
)
