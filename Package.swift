// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RememBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "RememBar", targets: ["BrowserMemoryBar"])
    ],
    targets: [
        .executableTarget(
            name: "BrowserMemoryBar",
            dependencies: ["Sparkle"],
            resources: [
                .process("Resources")
            ],
            // Runtime rpath so the bundled binary finds Sparkle.framework that the build script
            // embeds in Contents/Frameworks. Linking Sparkle WITHOUT this + the embed = dyld crash.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        // Local binaryTarget (SPM's remote artifact downloader hangs in some sandboxes). The
        // xcframework is gitignored + vendored by scripts/fetch-sparkle.sh — run it once after clone.
        .binaryTarget(name: "Sparkle", path: "Vendor/Sparkle.xcframework"),
        .testTarget(name: "BrowserMemoryBarTests", dependencies: ["BrowserMemoryBar"])
    ]
)
