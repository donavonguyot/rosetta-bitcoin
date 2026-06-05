// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "swiftbitnode",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "swiftbitnode", targets: ["swiftbitnode"])
    ],
    targets: [
        .systemLibrary(
            name: "CRocksDB",
            pkgConfig: "rocksdb",
            providers: [
                .apt(["librocksdb-dev"])
            ]
        ),
        .systemLibrary(
            name: "CSecp256k1",
            pkgConfig: "libsecp256k1",
            providers: [
                .apt(["libsecp256k1-dev"])
            ]
        ),
        .executableTarget(
            name: "swiftbitnode"
        ),
        .testTarget(
            name: "swiftbitnodeTests"
        )
    ]
)
