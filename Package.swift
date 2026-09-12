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

/// Les mêmes, **sans** `strictMemorySafety`.
///
/// `SUFirestoreLive` n'existe que pour parler au SDK Firebase, écrit en Objective-C. Le
/// réglage y signale alors **chaque appel** vers lui — une trentaine de lignes qui
/// n'apprennent rien, puisque l'interop est précisément le métier de cette cible. Le garder
/// noierait les cas où il dit vraiment quelque chose, dans les cinq autres cibles qui sont
/// du Swift pur.
///
/// Écrit en clair plutôt que dérivé de `commonSwiftSettings` : un `dropLast()` dépendrait
/// de l'ordre des réglages, et le jour où on en ajoute un, il retirerait le mauvais.
let interopSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
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
        .library(name: "SULogger", targets: ["SULogger"]),
        .library(name: "SUAuth", targets: ["SUAuth"]),
        .library(name: "SUAuthLive", targets: ["SUAuthLive"]),
        .library(name: "SUStorage", targets: ["SUStorage"]),
        .library(name: "SUStorageLive", targets: ["SUStorageLive"]),
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
            dependencies: ["SULogger"],
            swiftSettings: commonSwiftSettings
        ),
        .target(
            name: "SUNetworking",
            dependencies: ["SULogger"],
            swiftSettings: commonSwiftSettings
        ),
        .target(
            name: "SULogger",
            swiftSettings: commonSwiftSettings
        ),
        .target(
            name: "SUAuth",
            dependencies: ["SULogger"],
            swiftSettings: commonSwiftSettings
        ),
        .target(
            name: "SUAuthLive",
            dependencies: [
                "SUAuth",
                .product(
                    name: "FirebaseAuth",
                    package: "firebase-ios-sdk",
                    condition: .when(traits: ["Firebase"])
                ),
            ],
            swiftSettings: interopSwiftSettings
        ),
        .target(
            name: "SUStorage",
            dependencies: ["SULogger"],
            swiftSettings: commonSwiftSettings
        ),
        .target(
            name: "SUStorageLive",
            dependencies: [
                "SUStorage",
                .product(
                    name: "FirebaseStorage",
                    package: "firebase-ios-sdk",
                    condition: .when(traits: ["Firebase"])
                ),
            ],
            swiftSettings: interopSwiftSettings
        ),
        .target(
            name: "SUFirestore",
            dependencies: ["SULogger"],
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
            swiftSettings: interopSwiftSettings
        ),
        .testTarget(
            name: "SUPersistenceTests",
            dependencies: ["SUPersistence", "SULogger"],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "SUNetworkingTests",
            dependencies: ["SUNetworking"],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "SULoggerTests",
            dependencies: ["SULogger"],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "SUFirestoreLiveTests",
            dependencies: ["SUFirestore", "SUFirestoreLive"],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "SUAuthTests",
            dependencies: ["SUAuth", "SULogger"],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "SUStorageTests",
            dependencies: ["SUStorage", "SULogger"],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "SUFirestoreTests",
            dependencies: ["SUFirestore", "SULogger"],
            swiftSettings: commonSwiftSettings
        ),
    ]
)
