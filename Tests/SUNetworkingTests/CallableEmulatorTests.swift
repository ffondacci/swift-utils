import Foundation
import Testing
@testable import SUNetworking

/// Les mêmes vérifications que ``CallableEndpointTests``, mais contre un **vrai**
/// émulateur Firebase.
///
/// Un mock vérifie que le code fait ce qu'on a décidé ; il ne dit pas si ce qu'on a décidé
/// est juste. Ces tests-là répondent à l'autre question — le format `onCall` est-il bien
/// celui qu'on croit ?
///
/// Ils se **sautent tout seuls** sans `SU_EMULATOR=1`, pour que `swift test` reste vert sur
/// une machine où l'émulateur ne tourne pas.
///
/// ```bash
/// cd Tests/Fixtures/emulator
/// firebase emulators:start --only functions --project demo-swift-utils
/// SU_EMULATOR=1 swift test --filter CallableEmulatorTests
/// ```
@MainActor
@Suite("Émulateur — format onCall réel", .enabled(if: emulatorIsRequested))
struct CallableEmulatorTests {

    struct Echo: Codable, Sendable, Equatable {
        var received: Feedback?
        var hadAuth: Bool
    }

    private func makeStore() -> NetworkStore {
        NetworkStore(
            environment: APIEnvironment([
                .cloudFunctions: URL(string: "http://127.0.0.1:5001/demo-swift-utils/us-central1")!
            ]),
            defaultPolicy: RequestPolicy(timeout: .seconds(10), retry: .disabled)
        )
    }

    @Test("l'enveloppe data/result fait l'aller-retour avec une vraie fonction")
    func envelopeRoundTrips() async throws {
        let store = makeStore()
        let feedback = Feedback(message: "bonjour", rating: 5)

        let echo: Echo = try await store.send(
            Callable("echoPayload", payload: feedback, authentication: .none)
        )

        #expect(echo.received == feedback, "la fonction a bien reçu data")
        #expect(echo.hadAuth == false)
    }

    @Test("une fonction qui ne rend rien répond result null, et ça passe")
    func nullResultIsAccepted() async throws {
        let store = makeStore()

        let _: NoResult = try await store.send(
            Callable("returnsNothing", authentication: .none)
        )
    }

    @Test("une HttpsError remonte son code et son message, pas du JSON brut")
    func httpsErrorIsTyped() async throws {
        let store = makeStore()

        let error = await #expect(throws: NetworkError.self) {
            let _: Echo = try await store.send(
                Callable("failsWithError", authentication: .none)
            )
        }

        guard case let .serviceFailed(context, code, message) = error else {
            Issue.record("attendu .serviceFailed, reçu \(String(describing: error))")
            return
        }
        #expect(code == "PERMISSION_DENIED")
        #expect(message == "pas le droit")
        #expect(context.statusCode == 403)
    }

    @Test("un refus d'authentification remonte UNAUTHENTICATED en 401")
    func unauthenticatedIsTyped() async throws {
        let store = makeStore()

        let error = await #expect(throws: NetworkError.self) {
            let _: Echo = try await store.send(
                Callable("requiresAuth", authentication: .none)
            )
        }

        guard case let .serviceFailed(context, code, _) = error else {
            Issue.record("attendu .serviceFailed, reçu \(String(describing: error))")
            return
        }
        #expect(code == "UNAUTHENTICATED")
        #expect(context.statusCode == 401)
    }

    @Test("une fonction inexistante reste une erreur HTTP générique")
    func unknownFunctionStaysGeneric() async throws {
        let store = makeStore()

        let error = await #expect(throws: NetworkError.self) {
            let _: Echo = try await store.send(
                Callable("nexistePas", authentication: .none)
            )
        }

        // Le 404 de l'émulateur n'a pas l'enveloppe onCall : `mapError` rend nil et le
        // client produit son erreur générique, sans rien inventer.
        guard case .httpFailed = error else {
            Issue.record("attendu .httpFailed, reçu \(String(describing: error))")
            return
        }
        #expect(error?.statusCode == 404)
    }
}
