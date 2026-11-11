// swift-tools-version: 5.9

import PackageDescription

// Complete concurrency checking in every build and in the editor, not only in
// the gate's separate strict step.
let strictConcurrency: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency")]

let package = Package(
    name: "TaskScope",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TaskScope", targets: ["TaskScope"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/nalexn/ViewInspector.git",
            exact: "0.10.5"
        )
    ],
    targets: [
        .executableTarget(name: "TaskScope", swiftSettings: strictConcurrency),
        .testTarget(
            name: "TaskScopeTests",
            dependencies: [
                "TaskScope",
                .product(name: "ViewInspector", package: "ViewInspector")
            ],
            swiftSettings: strictConcurrency
        )
    ]
)
