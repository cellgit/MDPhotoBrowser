// swift-tools-version: 6.0
import PackageDescription

// 零第三方依赖：只用系统框架（SwiftUI、UIKit、ImageIO）。
// 二进制分发走 xcframework，见 scripts/build-xcframework.sh；两条路编的是同一份 Sources/MDPhotoBrowser。
let package = Package(
    name: "MDPhotoBrowser",
    defaultLocalization: "en",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MDPhotoBrowser", targets: ["MDPhotoBrowser"]),
    ],
    targets: [
        .target(
            name: "MDPhotoBrowser",
            resources: [
                .process("Localizable.xcstrings"),
                .copy("PrivacyInfo.xcprivacy"),
            ]
        ),
        .testTarget(
            name: "MDPhotoBrowserTests",
            dependencies: ["MDPhotoBrowser"]
        ),
    ]
)
