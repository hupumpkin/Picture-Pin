// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DesignPeekDraft",
    platforms: [.macOS(.v26)],
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
