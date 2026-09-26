// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TZBox",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TZBoxCore", targets: ["TZBoxCore"]),
        .executable(name: "TZBoxApp", targets: ["TZBoxApp"]),
        .executable(name: "TZBoxDiagnostics", targets: ["TZBoxDiagnostics"])
    ],
    targets: [
        .target(name: "TZBoxCore"),
        .executableTarget(name: "TZBoxApp", dependencies: ["TZBoxCore"]),
        .executableTarget(name: "TZBoxDiagnostics", dependencies: ["TZBoxCore"]),
        .testTarget(name: "TZBoxCoreTests", dependencies: ["TZBoxCore"])
    ]
)
