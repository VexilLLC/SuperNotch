// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SuperNotch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SuperNotch", targets: ["SuperNotch"]),
        .executable(name: "SuperNotchChargeHelper", targets: ["SuperNotchChargeHelper"])
    ],
    targets: [
        .target(name: "ChargeLimitCore"),
        .executableTarget(name: "SuperNotch", dependencies: ["ChargeLimitCore"]),
        .executableTarget(name: "SuperNotchChargeHelper", dependencies: ["ChargeLimitCore"]),
        .testTarget(name: "SuperNotchTests", dependencies: ["SuperNotch", "ChargeLimitCore"])
    ],
    swiftLanguageModes: [.v5]
)
