import Foundation
import Testing
@testable import SUFirestore

/// Un lot est atomique : ou tout passe, ou rien.
@MainActor
@Suite("Lots d'écriture")
struct WriteBatchTests {

    @Test("un lot vide ne fait rien et ne jette pas")
    func emptyBatchIsANoOp() async throws {
        let (store, client) = makeStore()

        try await store.batch { _ in }

        let paths = await client.storedPaths
        #expect(paths.isEmpty)
    }

    @Test("les écritures d'un lot sont toutes appliquées")
    func batchAppliesEverything() async throws {
        let (store, _) = makeStore()

        try await store.batch { batch in
            batch.set(profile("Alice"), id: "a", in: .profiles)
            batch.set(profile("Bob"), id: "b", in: .profiles)
        }

        let all = try await store.documents(in: .profiles)
        #expect(Set(all.map(\.id)) == ["a", "b"])
    }

    @Test("un lot mélange création, mise à jour et suppression")
    func batchMixesOperations() async throws {
        let (store, _) = makeStore()
        try await store.setDocument(profile("Ancien", visits: 1), id: "a", in: .profiles)
        try await store.setDocument(profile("À supprimer"), id: "b", in: .profiles)

        try await store.batch { batch in
            batch.update(["visits": 99], id: "a", in: .profiles)
            batch.delete(id: "b", in: .profiles)
            batch.set(profile("Nouveau"), id: "c", in: .profiles)
        }

        let all = try await store.documents(in: .profiles)
        let updated = try await store.document("a", in: .profiles)
        #expect(Set(all.map(\.id)) == ["a", "c"])
        #expect(updated?.visits == 99)
        #expect(updated?.name == "Ancien", "la mise à jour n'a touché qu'au champ nommé")
    }

    @Test("une opération qui échoue annule tout le lot")
    func failureRollsBackTheWholeBatch() async throws {
        let (store, _) = makeStore()
        try await store.setDocument(profile("Intact", visits: 1), id: "a", in: .profiles)

        let error = await #expect(throws: FirestoreError.self) {
            try await store.batch { batch in
                batch.set(profile("Créé"), id: "nouveau", in: .profiles)
                batch.update(["visits": 2], id: "inexistant", in: .profiles)   // échoue ici
            }
        }

        #expect(error == .notFound(path: "profiles/inexistant"))

        let created = try await store.document("nouveau", in: .profiles)
        let untouched = try await store.document("a", in: .profiles)
        #expect(created == nil, "l'écriture qui précédait l'échec n'a pas été publiée")
        #expect(untouched?.visits == 1)
    }

    @Test("le merge d'un lot se comporte comme celui d'une écriture simple")
    func batchMergeKeepsFields() async throws {
        let (store, client) = makeStore()
        try await client.seed(profile("Florent", visits: 42, premium: true), at: "profiles/u1")

        struct VisitsOnly: Codable, Sendable { var visits: Int }
        try await store.batch { batch in
            batch.set(VisitsOnly(visits: 43), at: DocumentPath<VisitsOnly>("profiles/u1"), merge: true)
        }

        let loaded = try await store.document("u1", in: .profiles)
        #expect(loaded?.visits == 43)
        #expect(loaded?.name == "Florent")
    }

    @Test("un lot au-delà de 500 écritures est refusé avant d'atteindre le réseau")
    func batchLimitIsEnforced() async throws {
        let (store, client) = makeStore()

        let error = await #expect(throws: FirestoreError.self) {
            try await store.batch { batch in
                for index in 0...DocumentBatch.maximumOperations {
                    batch.set(profile("p\(index)"), id: "\(index)", in: .profiles)
                }
            }
        }

        guard case let .invalidArgument(_, reason) = error else {
            Issue.record("attendu .invalidArgument, reçu \(String(describing: error))")
            return
        }
        #expect(reason.contains("501"))
        let paths = await client.storedPaths
        #expect(paths.isEmpty, "rien n'a été écrit")
    }

    @Test("exactement 500 écritures passent")
    func batchAtTheLimitIsAccepted() async throws {
        let (store, _) = makeStore()

        try await store.batch { batch in
            for index in 0..<DocumentBatch.maximumOperations {
                batch.set(profile("p\(index)"), id: "\(index)", in: .profiles)
            }
        }

        let count = try await store.documents(in: .profiles).count
        #expect(count == DocumentBatch.maximumOperations)
    }
}
