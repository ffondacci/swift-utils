import Foundation
import Testing
@testable import SUFirestore

/// D'où vient la donnée — la question qu'une app doit pouvoir poser avant d'afficher des
/// données de la semaine dernière comme si elles étaient fraîches.
@MainActor
@Suite("Provenance")
struct MetadataTests {

    @Test("par défaut, une lecture est annoncée synchronisée")
    func defaultsToSynchronized() async throws {
        let (store, _) = makeStore()
        try await store.setDocument(profile("Florent"), id: "u1", in: .profiles)

        let snapshot = try await store.snapshot("u1", in: .profiles)

        #expect(snapshot?.metadata.isFromCache == false)
        #expect(snapshot?.metadata.hasPendingWrites == false)
        #expect(snapshot?.metadata.isFresh == true)
    }

    @Test("une lecture venue du cache le dit")
    func cacheIsReported() async throws {
        let (store, client) = makeStore()
        try await store.setDocument(profile("Florent"), id: "u1", in: .profiles)
        await client.simulate(FirestoreMetadata(isFromCache: true, hasPendingWrites: false))

        let snapshot = try await store.snapshot("u1", in: .profiles)

        #expect(snapshot?.metadata.isFromCache == true)
        #expect(snapshot?.metadata.isFresh == false, "une donnée du cache n'est pas fraîche")
        #expect(snapshot?.value.name == "Florent", "la valeur reste lisible")
    }

    @Test("des écritures en attente le disent aussi")
    func pendingWritesAreReported() async throws {
        let (store, client) = makeStore()
        try await store.setDocument(profile("Florent"), id: "u1", in: .profiles)
        await client.simulate(FirestoreMetadata(isFromCache: false, hasPendingWrites: true))

        let snapshot = try await store.snapshot("u1", in: .profiles)

        #expect(snapshot?.metadata.hasPendingWrites == true)
        #expect(snapshot?.metadata.isFresh == false, "le serveur n'a pas encore confirmé")
    }

    @Test("une requête porte la provenance de tout le résultat")
    func queryCarriesMetadata() async throws {
        let (store, client) = makeStore()
        try await store.setDocument(profile("A"), id: "a", in: .profiles)
        try await store.setDocument(profile("B"), id: "b", in: .profiles)
        await client.simulate(FirestoreMetadata(isFromCache: true, hasPendingWrites: false))

        let result = try await store.query(in: .profiles)

        #expect(result.metadata.isFromCache == true)
        #expect(result.count == 2)
        #expect(result.documents.allSatisfy { $0.metadata.isFromCache })
    }

    @Test("la forme courte reste disponible quand la provenance n'intéresse pas")
    func plainFormStillWorks() async throws {
        let (store, _) = makeStore()
        try await store.setDocument(profile("Florent"), id: "u1", in: .profiles)

        let value = try await store.document("u1", in: .profiles)
        let values = try await store.query(in: .profiles).values

        #expect(value?.name == "Florent")
        #expect(values.count == 1)
    }

    @Test("un document absent n'a pas de provenance à porter")
    func missingDocumentHasNoSnapshot() async throws {
        let (store, _) = makeStore()

        let snapshot = try await store.snapshot("jamais", in: .profiles)
        #expect(snapshot == nil)
    }
}
