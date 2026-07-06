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
    dependencies: [
        // Shared 400faces macOS design system — public + tagged, so CI (and any fresh clone) resolves it
        // without a local checkout or credentials.
        .package(url: "https://github.com/400faces/MacFaceKit.git", from: "0.1.0")
    ],
    targets: [
        .executableTarget(
            name: "BrowserMemoryBar",
            dependencies: ["Sparkle", .product(name: "MacFaceKit", package: "MacFaceKit")],
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
