// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Embedded in the binary so macOS knows why it asks to control Messages
// (NSAppleEventsUsageDescription) and gives it a stable bundle identifier.
let infoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/talaria-bridge/Info.plist")
    .path

let package = Package(
    name: "TalariaBridge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "talaria-bridge", targets: ["talaria-bridge"]),
    ],
    targets: [
        .target(name: "TalariaObjC"),
        .target(name: "TalariaBridge", dependencies: ["TalariaObjC"]),
        .executableTarget(
            name: "talaria-bridge",
            dependencies: ["TalariaBridge"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
            ]
        ),
        .testTarget(
            name: "TalariaBridgeTests",
            dependencies: ["TalariaBridge"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
