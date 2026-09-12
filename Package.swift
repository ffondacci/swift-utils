// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-utils",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .watchOS(.v11),
        .tvOS(.v18),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "SUPersistence", targets: ["SUPersistence"]),
    ],
    targets: [
        .target(
            name: "SUPersistence",
            swiftSettings: [
                // Impose `any` devant chaque existentiel : on voit au premier coup d'œil
                // où le code paie une indirection dynamique.
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "SUPersistenceTests",
            dependencies: ["SUPersistence"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ]
)
