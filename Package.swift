// swift-tools-version: 6.2
import PackageDescription

/// Les réglages communs à toutes les cibles du dépôt.
///
/// Ils ne sont pas décoratifs — chacun change la sémantique du code :
///
/// - `defaultIsolation(nil)` grave la règle « une brique n'impose pas son isolation à
///   l'app qui la consomme ». Seuls les stores sont `@MainActor`, et c'est explicite.
/// - `NonisolatedNonsendingByDefault` (SE-0461) : une fonction `async` s'exécute sur
///   l'isolation de son **appelant** au lieu de sauter sur l'executor global. Moins de
///   sauts inutiles, et moins d'exigences `Sendable` sur ce qui traverse.
/// - `InferIsolatedConformances` (SE-0470) : une conformance d'un type `@MainActor` est
///   déduite isolée, au lieu d'exiger une annotation à chaque fois.
/// - `ExistentialAny` impose `any` devant chaque existentiel : on voit où le code paie
///   une indirection dynamique.
/// - `strictMemorySafety` signale tout usage d'API non sûre. Aucun dans ce dépôt, et
///   c'est ce qu'on veut garder.
let commonSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .strictMemorySafety(),
]

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
        .library(name: "SUNetworking", targets: ["SUNetworking"]),
        .library(name: "SUFirestore", targets: ["SUFirestore"]),
        .library(name: "SUFirestoreLive", targets: ["SUFirestoreLive"]),
    ],
    traits: [
        .default(enabledTraits: []),
        .trait(
            name: "Firebase",
            description: """
                Active SUFirestoreLive, l'adaptateur qui parle au SDK Firebase.

                Sans ce trait, firebase-ios-sdk n'est ni téléchargé ni compilé — une app \
                qui n'utilise que SUPersistence ou SUNetworking ne paie rien. Avec, elle \
                hérite du SDK et de ses onze paquets transitifs.

                SUFirestore, lui, reste disponible dans tous les cas : son vocabulaire, \
                ses erreurs et son double en mémoire n'ont aucune dépendance.
                """
        ),
    ],
    dependencies: [
        // Résolue uniquement si le trait « Firebase » est actif : SwiftPM élague les
        // dépendances dont le seul usage est derrière un trait désactivé.
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "11.0.0"),
    ],
    targets: [
        .target(
            name: "SUPersistence",
            swiftSettings: commonSwiftSettings
        ),
        .target(
            name: "SUNetworking",
            swiftSettings: commonSwiftSettings
        ),
        .target(
            name: "SUFirestore",
            swiftSettings: commonSwiftSettings
        ),
        .target(
            name: "SUFirestoreLive",
            dependencies: [
                "SUFirestore",
                .product(
                    name: "FirebaseFirestore",
                    package: "firebase-ios-sdk",
                    condition: .when(traits: ["Firebase"])
                ),
            ],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "SUPersistenceTests",
            dependencies: ["SUPersistence"],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "SUNetworkingTests",
            dependencies: ["SUNetworking"],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "SUFirestoreTests",
            dependencies: ["SUFirestore"],
            swiftSettings: commonSwiftSettings
        ),
    ]
)
