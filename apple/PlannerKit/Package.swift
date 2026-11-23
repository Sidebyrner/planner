// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PlannerKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PlannerKit", targets: ["PlannerKit"]),
    ],
    targets: [
        .target(name: "PlannerKit"),
        .testTarget(name: "PlannerKitTests", dependencies: ["PlannerKit"]),
    ]
)
