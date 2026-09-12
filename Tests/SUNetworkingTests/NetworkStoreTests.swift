import Foundation
import Testing
@testable import SUNetworking

/// La surface publique : ce que les vues observent, et ce que le store fait d'une erreur.
@MainActor
@Suite("Store")
struct NetworkStoreTests {

    private func makeStore(
        _ outcomes: [MockTransport.Outcome] = [.status(200, json: greetingJSON())]
    ) -> NetworkStore {
        NetworkStore(
            environment: testEnvironment,
            transport: MockTransport(outcomes),
            defaultPolicy: RequestPolicy(retry: .disabled)
        )
    }

    @Test("au repos, rien n'est en vol et aucune erreur n'est affichée")
    func startsIdle() {
        let store = makeStore()

        #expect(store.isLoading == false)
        #expect(store.inFlightCount == 0)
        #expect(store.lastError == nil)
    }

    @Test("le compteur de requêtes revient à zéro après un succès")
    func inFlightCountReturnsToZero() async throws {
        let store = makeStore()

        _ = try await store.send(GetGreeting())

        #expect(store.inFlightCount == 0)
        #expect(store.isLoading == false)
    }

    @Test("le compteur revient à zéro même quand la requête échoue")
    func inFlightCountReturnsToZeroOnFailure() async throws {
        let store = makeStore([.status(500)])

        _ = await #expect(throws: NetworkError.self) {
            try await store.send(GetGreeting())
        }

        #expect(store.inFlightCount == 0)
    }

    @Test("une erreur est retenue pour être affichée")
    func failureIsRetained() async throws {
        let store = makeStore([.status(500)])

        _ = await #expect(throws: NetworkError.self) {
            try await store.send(GetGreeting())
        }

        #expect(store.lastError?.statusCode == 500)
    }

    @Test("une annulation n'est pas retenue comme une erreur")
    func cancellationIsNotAnError() async throws {
        let store = NetworkStore(client: FailingClient(error: .cancelled))

        _ = await #expect(throws: NetworkError.self) {
            try await store.send(GetGreeting())
        }

        #expect(store.lastError == nil)
    }

    @Test("une requête réussie n'efface pas une erreur que l'utilisateur n'a pas vue")
    func successDoesNotClearPreviousError() async throws {
        let store = makeStore([.status(500), .status(200, json: greetingJSON())])

        _ = await #expect(throws: NetworkError.self) {
            try await store.send(GetGreeting())
        }
        _ = try await store.send(SearchGreetings(term: "x"))

        #expect(store.lastError?.statusCode == 500)
    }

    @Test("l'erreur s'efface quand on le demande explicitement")
    func errorIsClearedOnDemand() async throws {
        let store = makeStore([.status(500)])
        _ = await #expect(throws: NetworkError.self) {
            try await store.send(GetGreeting())
        }

        store.clearLastError()

        #expect(store.lastError == nil)
    }

    @Test("l'erreur du client remonte telle quelle jusqu'à l'appelant")
    func errorPropagates() async throws {
        let expected = NetworkError.tokenUnavailable(reason: "session expirée")
        let store = NetworkStore(client: FailingClient(error: expected))

        let error = await #expect(throws: NetworkError.self) {
            try await store.send(GetGreeting())
        }

        #expect(error == expected)
    }
}
