import Foundation
import Testing
@testable import SUPersistence

/// La surface publique : cache observé, ordre des opérations, propagation des erreurs.
@MainActor
@Suite("Store")
struct PersistenceStoreTests {

    @Test("avant tout chargement, la lecture synchrone rend la valeur par défaut")
    func defaultsBeforeLoad() {
        let store = PersistenceStore.inMemory()

        #expect(store.value(for: .onboardingDone) == false)
        #expect(store[.launchCount] == 0)
    }

    @Test("après save, la lecture synchrone rend la nouvelle valeur")
    func saveUpdatesCache() async throws {
        let store = PersistenceStore.inMemory()

        try await store.save(true, for: .onboardingDone)

        #expect(store[.onboardingDone] == true)
    }

    @Test("load remplit le cache depuis le support")
    func loadFillsCache() async throws {
        let backend = InMemoryBackend()
        let store = PersistenceStore(repository: CodableRepository(backend: backend))
        try await store.save(7, for: .launchCount)

        // Un store neuf sur le même support : le cache part vide.
        let other = PersistenceStore(repository: CodableRepository(backend: backend))
        #expect(other[.launchCount] == 0)

        try await other.load(.launchCount)
        #expect(other[.launchCount] == 7)
    }

    @Test("une écriture qui échoue laisse le cache intact")
    func failedSaveLeavesCacheUntouched() async throws {
        let store = PersistenceStore(
            repository: FailingRepository(error: .writeFailed(key: "launchCount", reason: "disque plein"))
        )

        await #expect(throws: PersistenceError.self) {
            try await store.save(99, for: .launchCount)
        }

        #expect(store[.launchCount] == 0)
    }

    @Test("l'erreur du repository remonte telle quelle jusqu'à l'appelant")
    func errorPropagates() async throws {
        let expected = PersistenceError.storageUnavailable(reason: "suite absente")
        let store = PersistenceStore(repository: FailingRepository(error: expected))

        let error = await #expect(throws: PersistenceError.self) {
            try await store.load(.onboardingDone)
        }

        #expect(error == expected)
    }

    @Test("remove ramène la valeur par défaut, en cache comme sur le support")
    func removeRestoresDefault() async throws {
        let store = PersistenceStore.inMemory()
        try await store.save(42, for: .launchCount)

        try await store.remove(.launchCount)

        let reloaded = try await store.load(.launchCount)

        #expect(store[.launchCount] == 0)
        #expect(reloaded == 0)
    }

    @Test("removeAll vide le support et le cache")
    func removeAllClearsBoth() async throws {
        let store = PersistenceStore.inMemory()
        try await store.save(true, for: .onboardingDone)
        try await store.save(3, for: .launchCount)

        try await store.removeAll()

        let present = try await store.contains(.onboardingDone)

        #expect(store[.onboardingDone] == false)
        #expect(store[.launchCount] == 0)
        #expect(present == false)
    }

    @Test("deux clés de types différents ne se marchent pas dessus")
    func keysAreIndependent() async throws {
        let store = PersistenceStore.inMemory()

        try await store.save(true, for: .onboardingDone)
        try await store.save(5, for: .launchCount)
        try await store.save(Profile(name: "Lensy", visits: 1, lastSeen: nil), for: .profile)

        #expect(store[.onboardingDone] == true)
        #expect(store[.launchCount] == 5)
        #expect(store[.profile].name == "Lensy")
    }
}
