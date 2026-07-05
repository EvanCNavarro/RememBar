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
        // Shared 400faces macOS design system. Local path during migration (the kit is a private repo
        // with no tags yet — a git URL wouldn't resolve reproducibly for a shipping build). Both repos
        // live on disk; switch to the git URL once the kit is public + tagged. github.com/400faces/MacFaceKit
        .package(path: "../../../Developer/MacFaceKit")
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
