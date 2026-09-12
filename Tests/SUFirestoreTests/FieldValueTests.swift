import Foundation
import Testing
@testable import SUFirestore

/// Les opérations que le **serveur** applique, sans lecture préalable : incrément,
/// ajout et retrait dans un tableau.
@MainActor
@Suite("Opérations serveur")
struct FieldValueTests {

    @Test("un incrément ajoute au nombre en place")
    func incrementAdds() async throws {
        let (store, _) = makeStore()
        try await store.setDocument(profile("Florent", visits: 10), id: "u1", in: .profiles)

        try await store.updateDocument(["visits": .increment(5)], id: "u1", in: .profiles)

        let loaded = try await store.document("u1", in: .profiles)
        #expect(loaded?.visits == 15)
    }

    @Test("deux incréments successifs s'additionnent, ils ne s'écrasent pas")
    func incrementsAccumulate() async throws {
        let (store, _) = makeStore()
        try await store.setDocument(profile("Florent", visits: 0), id: "u1", in: .profiles)

        try await store.updateDocument(["visits": .increment(3)], id: "u1", in: .profiles)
        try await store.updateDocument(["visits": .increment(4)], id: "u1", in: .profiles)

        let loaded = try await store.document("u1", in: .profiles)
        #expect(loaded?.visits == 7, "c'est tout l'intérêt : deux appareils ne s'écrasent pas")
    }

    @Test("arrayUnion ajoute sans doublon")
    func arrayUnionAvoidsDuplicates() async throws {
        let (store, _) = makeStore()
        try await store.setDocument(profile("Florent", tags: ["a"]), id: "u1", in: .profiles)

        try await store.updateDocument(["tags": .arrayUnion(["b", "a"])], id: "u1", in: .profiles)

        let loaded = try await store.document("u1", in: .profiles)
        #expect(loaded?.tags == ["a", "b"])
    }

    @Test("arrayRemove retire les éléments nommés")
    func arrayRemoveDrops() async throws {
        let (store, _) = makeStore()
        try await store.setDocument(profile("Florent", tags: ["a", "b", "c"]), id: "u1", in: .profiles)

        try await store.updateDocument(["tags": .arrayRemove(["b"])], id: "u1", in: .profiles)

        let loaded = try await store.document("u1", in: .profiles)
        #expect(loaded?.tags == ["a", "c"])
    }

    // MARK: - L'interaction avec la reprise

    @Test("une écriture qui contient un incrément n'est jamais rejouée")
    func incrementsAreNeverRetried() async throws {
        let client = InMemoryFirestore()
        let store = FirestoreStore(
            client: RetryingFirestore(
                wrapping: client,
                policy: FirestoreRetryPolicy(maxRetries: 3, backoff: .constant(.milliseconds(1)))
            )
        )
        try await client.seed(profile("Florent", visits: 0), at: "profiles/u1")
        await client.failNextCalls(1, with: .aborted(reason: "contention"))

        _ = await #expect(throws: FirestoreError.self) {
            try await store.updateDocument(["visits": .increment(1)], id: "u1", in: .profiles)
        }

        // Rejouer aurait pu compter deux fois : le serveur a peut-être appliqué
        // l'incrément avant de ne pas répondre.
        // `seed` ne passe pas par le compteur : c'est bien un seul essai d'écriture.
        let count = await client.callCount
        #expect(count == 1, "une seule tentative, pas de reprise")
    }

    @Test("une écriture absolue, elle, est bien rejouée")
    func absoluteWritesAreStillRetried() async throws {
        let client = InMemoryFirestore()
        let store = FirestoreStore(
            client: RetryingFirestore(
                wrapping: client,
                policy: FirestoreRetryPolicy(maxRetries: 3, backoff: .constant(.milliseconds(1)))
            )
        )
        try await client.seed(profile("Florent", visits: 0), at: "profiles/u1")
        await client.failNextCalls(1, with: .aborted(reason: "contention"))

        try await store.updateDocument(["visits": 5], id: "u1", in: .profiles)

        let loaded = try await store.document("u1", in: .profiles)
        let count = await client.callCount
        #expect(loaded?.visits == 5)
        #expect(count == 3, "un échec, une reprise, puis la relecture")
    }

    @Test("un lot contenant un incrément n'est pas rejouable non plus")
    func batchWithIncrementIsNotRetried() async throws {
        let client = InMemoryFirestore()
        let store = FirestoreStore(
            client: RetryingFirestore(
                wrapping: client,
                policy: FirestoreRetryPolicy(maxRetries: 3, backoff: .constant(.milliseconds(1)))
            )
        )
        try await client.seed(profile("Florent", visits: 0), at: "profiles/u1")
        await client.failNextCalls(1, with: .aborted(reason: "contention"))

        _ = await #expect(throws: FirestoreError.self) {
            try await store.batch { batch in
                batch.update(["visits": .increment(1)], id: "u1", in: .profiles)
            }
        }

        let count = await client.callCount
        #expect(count == 1, "un seul essai")
    }

    @Test("arrayUnion et arrayRemove restent rejouables, parce qu'ils sont idempotents")
    func arrayOperationsAreIdempotent() {
        let union = DocumentWrite.update(path: "p", fields: ["tags": .arrayUnion(["a"])])
        let remove = DocumentWrite.update(path: "p", fields: ["tags": .arrayRemove(["a"])])
        let increment = DocumentWrite.update(path: "p", fields: ["n": .increment(1)])

        #expect(union.isIdempotent)
        #expect(remove.isIdempotent)
        #expect(increment.isIdempotent == false)
    }
}
