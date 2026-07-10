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
        // without a local checkout or credentials. Pinned to the 0.3.x line: the app uses 0.3.1+ APIs
        // (`ReleaseNotesParser.embeddedItems`, the shared `UpdateWindowController`), and up-to-next-minor
        // keeps builds reproducible while still taking patch fixes. Bump deliberately for a 0.4+ kit.
        .package(url: "https://github.com/400faces/MacFaceKit.git", .upToNextMinor(from: "0.3.2"))
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
