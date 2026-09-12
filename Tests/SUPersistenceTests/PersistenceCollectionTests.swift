import Foundation
import Testing
@testable import SUPersistence

/// Garder localement un ensemble de valeurs : y écrire, les relire, les compter, les
/// filtrer, les vider — sans toucher au reste du stockage.
@MainActor
@Suite("Collections")
struct PersistenceCollectionTests {

    private func makeStore() -> PersistenceStore { .inMemory() }

    private func profile(_ name: String, visits: Int) -> Profile {
        Profile(name: name, visits: visits, lastSeen: nil)
    }

    @Test("une collection vide n'a ni identifiant ni entrée")
    func emptyCollection() async throws {
        let store = makeStore()

        let ids = try await store.ids(in: .profiles)
        let all = try await store.loadAll(from: .profiles)
        let count = try await store.count(in: .profiles)

        #expect(ids.isEmpty)
        #expect(all.isEmpty)
        #expect(count == 0)
    }

    @Test("une entrée écrite se relit par son identifiant")
    func roundTripByID() async throws {
        let store = makeStore()
        let florent = profile("Florent", visits: 3)

        try await store.save(florent, id: "u1", in: .profiles)

        let loaded = try await store.load(id: "u1", from: .profiles)
        #expect(loaded == florent)
    }

    @Test("un identifiant absent rend nil, pas une valeur par défaut")
    func missingIDIsNil() async throws {
        let store = makeStore()

        let loaded = try await store.load(id: "jamais", from: .profiles)
        #expect(loaded == nil)
    }

    @Test("loadAll rend toutes les entrées par identifiant")
    func loadAllReturnsEverything() async throws {
        let store = makeStore()
        try await store.save(profile("A", visits: 1), id: "u1", in: .profiles)
        try await store.save(profile("B", visits: 2), id: "u2", in: .profiles)

        let all = try await store.loadAll(from: .profiles)

        #expect(all.count == 2)
        #expect(all["u1"]?.name == "A")
        #expect(all["u2"]?.name == "B")
    }

    @Test("saveAll écrit un lot d'un coup")
    func saveAllWritesBatch() async throws {
        let store = makeStore()

        try await store.saveAll(
            ["u1": profile("A", visits: 1), "u2": profile("B", visits: 2)],
            in: .profiles
        )

        let count = try await store.count(in: .profiles)
        #expect(count == 2)
    }

    @Test("le filtrage ne rend que les entrées qui satisfont le prédicat")
    func filterSelects() async throws {
        let store = makeStore()
        try await store.save(profile("assidu", visits: 50), id: "u1", in: .profiles)
        try await store.save(profile("rare", visits: 1), id: "u2", in: .profiles)

        let actifs = try await store.filter(.profiles) { $0.visits > 10 }

        #expect(actifs.count == 1)
        #expect(actifs.first?.name == "assidu")
    }

    @Test("réécrire un identifiant remplace son entrée")
    func overwritingAnID() async throws {
        let store = makeStore()
        try await store.save(profile("avant", visits: 1), id: "u1", in: .profiles)

        try await store.save(profile("après", visits: 2), id: "u1", in: .profiles)

        let loaded = try await store.load(id: "u1", from: .profiles)
        let count = try await store.count(in: .profiles)
        #expect(loaded?.name == "après")
        #expect(count == 1)
    }

    @Test("supprimer une entrée ne touche pas aux autres")
    func removingOneEntry() async throws {
        let store = makeStore()
        try await store.save(profile("A", visits: 1), id: "u1", in: .profiles)
        try await store.save(profile("B", visits: 2), id: "u2", in: .profiles)

        try await store.remove(id: "u1", from: .profiles)

        let ids = try await store.ids(in: .profiles)
        #expect(ids == ["u2"])
    }

    @Test("vider une collection ne touche pas aux autres collections")
    func clearingOneCollection() async throws {
        let store = makeStore()
        try await store.save(profile("A", visits: 1), id: "u1", in: .profiles)
        try await store.save(10, id: "s1", in: .scores)

        try await store.removeAll(from: .profiles)

        let profiles = try await store.count(in: .profiles)
        let scores = try await store.count(in: .scores)
        #expect(profiles == 0)
        #expect(scores == 1)
    }

    @Test("vider une collection ne touche pas aux clés simples")
    func clearingCollectionLeavesKeysAlone() async throws {
        let store = makeStore()
        try await store.save(42, for: .launchCount)
        try await store.save(profile("A", visits: 1), id: "u1", in: .profiles)

        try await store.removeAll(from: .profiles)

        let launchCount = try await store.load(.launchCount)
        #expect(launchCount == 42)
    }

    @Test("une collection et une clé simple du même nom ne se croisent pas")
    func collectionAndKeyAreNamespaced() async throws {
        let store = makeStore()
        let key = PersistenceKey<Int>("scores", default: 0)
        try await store.save(999, for: key)

        try await store.save(10, id: "s1", in: .scores)

        let simple = try await store.load(key)
        let ids = try await store.ids(in: .scores)
        #expect(simple == 999)
        #expect(ids == ["s1"])
    }

    @Test("un identifiant contenant des caractères de chemin reste une seule entrée")
    func awkwardIdentifiersAreSafe() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(
            repository: CodableRepository(backend: JSONDirectoryBackend(directory: directory))
        )

        try await store.save(profile("A", visits: 1), id: "../../evasion", in: .profiles)

        let loaded = try await store.load(id: "../../evasion", from: .profiles)
        let ids = try await store.ids(in: .profiles)
        #expect(loaded?.name == "A")
        #expect(ids == ["../../evasion"])
    }

    @Test("removeAll global vide aussi les collections")
    func globalRemoveAllClearsCollections() async throws {
        let store = makeStore()
        try await store.save(profile("A", visits: 1), id: "u1", in: .profiles)

        try await store.removeAll()

        let count = try await store.count(in: .profiles)
        #expect(count == 0)
    }
}
