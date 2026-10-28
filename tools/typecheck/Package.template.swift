// swift-tools-version: 5.9
// CI 临时包：用 SwiftSoup 真实实现编译 Core/RuleEngine/RuleEngine.swift，验证新写的规则代码能否通过类型检查
import PackageDescription

let package = Package(
    name: "EngineTypecheck",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "Engine",
            dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")],
            path: "Sources/Engine"
        )
    ]
)
