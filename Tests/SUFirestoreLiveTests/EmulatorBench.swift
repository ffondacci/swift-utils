#if Firebase
import Foundation
import FirebaseCore
import SUFirestore
import SUFirestoreLive
import Testing

/// Ces tests ne tournent qu'avec `SU_EMULATOR=1`, pour que `swift test` reste vert sur une
/// machine où l'émulateur ne tourne pas.
let emulatorIsRequested = ProcessInfo.processInfo.environment["SU_EMULATOR"] == "1"

/// Le client branché sur l'émulateur.
///
/// `FirebaseApp.configure()` ne peut avoir lieu qu'une fois par processus — c'est
/// exactement la contrainte que le module refuse de prendre en charge, et qu'une app doit
/// honorer. Une variable globale paresseuse le garantit.
let bench: LiveFirestore = {
    let options = FirebaseOptions(
        googleAppID: "1:1234567890:ios:0123456789abcdef",
        gcmSenderID: "1234567890"
    )
    options.projectID = "demo-swift-utils"
    options.apiKey = "fake-api-key-for-emulator"
    FirebaseApp.configure(options: options)

    return LiveFirestore(configuration: FirestoreConfiguration(
        emulator: .init(host: "127.0.0.1", port: 8080)
    ))
}()

struct Profile: Codable, Sendable, Equatable {
    var name: String
    var visits: Int
    var premium: Bool = false
    var tags: [String] = []
}

struct Event: Codable, Sendable, Equatable {
    var name: String
    var occurredAt: Date
    /// Optionnel : un `serverTimestamp` vaut `null` tant que le serveur n'a pas répondu.
    var recordedAt: Date?
}

/// Chaque test travaille dans sa propre collection : l'émulateur garde son état entre les
/// tests, et deux tests qui se marchent dessus donneraient des échecs illisibles.
func freshProfiles() -> CollectionPath<Profile> {
    CollectionPath("profiles-\(UUID().uuidString)")
}

func freshEvents() -> CollectionPath<Event> {
    CollectionPath("events-\(UUID().uuidString)")
}

@MainActor
func makeBenchStore() -> FirestoreStore {
    FirestoreStore(client: bench)
}
#endif
