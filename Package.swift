// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-ming-image: inclusionAI's Ming-Image 0.1 Design (MIT) as a Gaea plugin. One worker executable built on
// GaeaPluginKit over ming-image-swift, packaged as a signed .gaeaplugin by scripts/build-plugin.sh.
//
// ming-inproc is not part of the plugin: it runs the same package in-process through MLXServeEngine, with the same
// dependency resolution, as the reference a run through Gaea is compared against.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]

let package = Package(
    name: "gaea-plugin-ming-image",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.5.0"),
        .package(url: "https://github.com/xocialize/ming-image-swift.git", exact: "0.3.1"),
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.73.0"),
    ],
    targets: [
        .target(
            name: "MingPlugin",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLXMingImage", package: "ming-image-swift"),
                .product(name: "MingImage", package: "ming-image-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
            ]
        ),
        .executableTarget(
            name: "gaea-ming-image-worker",
            dependencies: [
                "MingPlugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
            ]
        ),
        .executableTarget(
            name: "ming-inproc",
            dependencies: [
                "MingPlugin",
                .product(name: "MLXMingImage", package: "ming-image-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
