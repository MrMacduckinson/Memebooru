// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Memebooru",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "MemebooruCore", targets: ["MemebooruCore"]),
        .library(name: "MemebooruPlatformApple", targets: ["MemebooruPlatformApple"]),
        .executable(name: "memebooru", targets: ["memebooru"]),
        .executable(name: "memebooru-server", targets: ["memebooru-server"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        // Bundled SQLite: same version + FTS5 on every platform.
        .target(
            name: "CSQLite",
            path: "Sources/CSQLite",
            cSettings: [
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_ENABLE_MATH_FUNCTIONS"),
                .define("SQLITE_THREADSAFE", to: "1"),
                .define("SQLITE_DQS", to: "0"),
                .define("SQLITE_DEFAULT_WAL_SYNCHRONOUS", to: "1"),
                .define("SQLITE_USE_URI", to: "1"),
                .define("SQLITE_OMIT_DEPRECATED"),
                .define("SQLITE_OMIT_LOAD_EXTENSION"),
                .define("SQLITE_LIKE_DOESNT_MATCH_BLOBS"),
            ]
        ),
        // stb_image / stb_image_resize2 / stb_image_write for non-Apple decode + fallback.
        .target(
            name: "CStbImage",
            path: "Sources/CStbImage"
        ),
        .target(
            name: "MemebooruCore",
            dependencies: [
                "CSQLite",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/MemebooruCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // nanosvg (zlib licence): SVG raster where the OS has no public SVG reader (iOS).
        .target(
            name: "CNanoSVG",
            path: "Sources/CNanoSVG",
            exclude: ["nanosvg.h", "nanosvgrast.h"]
        ),
        .target(
            name: "MemebooruPlatformApple",
            dependencies: ["MemebooruCore", "CNanoSVG"],
            path: "Sources/MemebooruPlatformApple",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MemebooruPlatformLinux",
            dependencies: ["MemebooruCore", "CStbImage"],
            path: "Sources/MemebooruPlatformLinux",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // POSIX TCP transport + sync server (Linux and macOS).
        .target(
            name: "MemebooruNet",
            dependencies: ["MemebooruCore"],
            path: "Sources/MemebooruNet",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Telegram bot: inline search + "forward to save".
        .target(
            name: "MemebooruBot",
            dependencies: ["MemebooruCore"],
            path: "Sources/MemebooruBot",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // VPS daemon: sync server + Telegram bot over one collection replica.
        .executableTarget(
            name: "memebooru-server",
            dependencies: [
                "MemebooruCore", "MemebooruNet", "MemebooruBot",
                "MemebooruPlatformApple", "MemebooruPlatformLinux",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/memebooru-server",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "memebooru",
            dependencies: [
                "MemebooruCore",
                "MemebooruNet",
                "MemebooruPlatformApple",
                "MemebooruPlatformLinux",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/memebooru",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MemebooruPlatformTests",
            dependencies: ["MemebooruCore", "MemebooruPlatformApple", "MemebooruPlatformLinux", "MemebooruBot", "CNanoSVG"],
            path: "Tests/MemebooruPlatformTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MemebooruBotTests",
            dependencies: ["MemebooruBot", "MemebooruCore"],
            path: "Tests/MemebooruBotTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MemebooruNetTests",
            dependencies: ["MemebooruNet", "MemebooruCore", "MemebooruPlatformApple"],
            path: "Tests/MemebooruNetTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The executables, tested in-process (`@testable import` of an executable target).
        .testTarget(
            name: "MemebooruCLITests",
            dependencies: [
                "memebooru", "MemebooruCore", "MemebooruNet",
                "MemebooruPlatformApple", "MemebooruPlatformLinux",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Tests/MemebooruCLITests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MemebooruServerTests",
            dependencies: [
                "memebooru-server", "MemebooruCore", "MemebooruNet", "MemebooruBot",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Tests/MemebooruServerTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MemebooruCoreTests",
            dependencies: ["MemebooruCore"],
            path: "Tests/MemebooruCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
