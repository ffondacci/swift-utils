import Foundation
import Testing
@testable import SUPersistence

/// « Est-ce encore frais ? » — la question qui décide entre le cache local et un appel
/// réseau.
@MainActor
@Suite("Fraîcheur")
struct StoredValueTests {

    @Test("une valeur écrite à l'instant n'est pas périmée")
    func freshValueIsNotStale() async throws {
        let store = PersistenceStore.inMemory()
        try await store.save(42, for: .launchCount)

        let entry = try await store.stored(.launchCount)

        #expect(entry?.value == 42)
        #expect(entry?.isStale(after: .seconds(60)) == false)
    }

    @Test("une valeur ancienne est déclarée périmée")
    func oldValueIsStale() {
        let entry = StoredValue(value: 42, storedAt: .now.addingTimeInterval(-3_600))

        #expect(entry.isStale(after: .seconds(60)) == true)
        #expect(entry.isStale(after: .seconds(7_200)) == false)
    }

    @Test("une horloge qui recule ne périme pas tout le cache")
    func negativeAgeIsNotStale() {
        // Correction NTP, changement d'heure : la date d'écriture se retrouve dans le futur.
        let entry = StoredValue(value: 42, storedAt: .now.addingTimeInterval(3_600))

        #expect(entry.isStale(after: .seconds(60)) == false)
    }

    @Test("une clé jamais écrite n'a pas d'enveloppe")
    func missingKeyHasNoEntry() async throws {
        let store = PersistenceStore.inMemory()

        let entry = try await store.stored(.launchCount)
        #expect(entry == nil)
    }

    @Test("stored distingue « jamais écrit » de « écrit la valeur par défaut »")
    func storedDistinguishesAbsenceFromDefault() async throws {
        let store = PersistenceStore.inMemory()

        let before = try await store.stored(.onboardingDone)
        try await store.save(false, for: .onboardingDone)
        let after = try await store.stored(.onboardingDone)

        #expect(before == nil)
        #expect(after?.value == false)
    }

    @Test("il faut rafraîchir quand la valeur est absente")
    func refreshNeededWhenMissing() async throws {
        let store = PersistenceStore.inMemory()

        let needs = try await store.needsRefresh(.launchCount, after: .seconds(60))
        #expect(needs == true)
    }

    @Test("il ne faut pas rafraîchir une valeur fraîche")
    func noRefreshNeededWhenFresh() async throws {
        let store = PersistenceStore.inMemory()
        try await store.save(42, for: .launchCount)

        let needs = try await store.needsRefresh(.launchCount, after: .seconds(60))
        #expect(needs == false)
    }

    @Test("une entrée de collection porte aussi sa date")
    func collectionEntriesAreTimestamped() async throws {
        let store = PersistenceStore.inMemory()
        let florent = Profile(name: "Florent", visits: 1, lastSeen: nil)
        try await store.save(florent, id: "u1", in: .profiles)

        let entry = try await store.stored(id: "u1", from: .profiles)

        #expect(entry?.value == florent)
        #expect(entry?.isStale(after: .seconds(60)) == false)
    }

    @Test("lire l'enveloppe alimente aussi le cache observé")
    func storedFillsCache() async throws {
        let backend = InMemoryBackend()
        let writer = PersistenceStore(repository: CodableRepository(backend: backend))
        try await writer.save(7, for: .launchCount)

        let reader = PersistenceStore(repository: CodableRepository(backend: backend))
        #expect(reader[.launchCount] == 0)

        _ = try await reader.stored(.launchCount)
        #expect(reader[.launchCount] == 7)
    }
}
