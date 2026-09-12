import Foundation
import Testing
@testable import SUFirestore

/// La contention est le cas nominal, pas l'exception : deux appareils qui écrivent le
/// même document au même instant sont une situation normale, dont Firestore sort en
/// abandonnant l'une des écritures.
@MainActor
@Suite("Reprise")
struct RetryingFirestoreTests {

    private func makeRetryingStore(
        policy: FirestoreRetryPolicy = FirestoreRetryPolicy(
            maxRetries: 3,
            backoff: .constant(.milliseconds(1))
        )
    ) -> (store: FirestoreStore, client: InMemoryFirestore) {
        let client = InMemoryFirestore()
        return (FirestoreStore(client: RetryingFirestore(wrapping: client, policy: policy)), client)
    }

    @Test("une contention est rejouée jusqu'au succès")
    func contentionIsRetried() async throws {
        let (store, client) = makeRetryingStore()
        await client.failNextCalls(2, with: .aborted(reason: "contention"))

        try await store.setDocument(profile("Florent"), id: "u1", in: .profiles)

        let count = await client.callCount
        #expect(count == 3, "deux échecs puis un succès")
    }

    @Test("un réseau coupé est rejoué")
    func unavailableIsRetried() async throws {
        let (store, client) = makeRetryingStore()
        await client.failNextCalls(1, with: .unavailable(reason: "hors ligne"))

        try await store.setDocument(profile("Florent"), id: "u1", in: .profiles)

        let loaded = try await store.document("u1", in: .profiles)
        #expect(loaded?.name == "Florent")
    }

    @Test("un refus des règles de sécurité n'est jamais rejoué")
    func permissionDeniedIsNotRetried() async throws {
        let (store, client) = makeRetryingStore()
        await client.failNextCalls(5, with: .permissionDenied(path: "profiles/u1", reason: "règles"))

        _ = await #expect(throws: FirestoreError.self) {
            try await store.document("u1", in: .profiles)
        }

        let count = await client.callCount
        #expect(count == 1, "un seul essai : ça ne s'arrangera pas tout seul")
    }

    @Test("un document mal formé n'est jamais rejoué")
    func decodingFailureIsNotRetried() async throws {
        let (store, client) = makeRetryingStore()
        await client.failNextCalls(5, with: .decodingFailed(path: "p", type: "Profile", reason: "r"))

        _ = await #expect(throws: FirestoreError.self) {
            try await store.document("u1", in: .profiles)
        }

        let count = await client.callCount
        #expect(count == 1)
    }

    @Test("les tentatives s'arrêtent au plafond, et l'erreur remonte")
    func stopsAtMaxRetries() async throws {
        let (store, client) = makeRetryingStore()
        await client.failNextCalls(10, with: .aborted(reason: "contention"))

        let error = await #expect(throws: FirestoreError.self) {
            try await store.setDocument(profile("Florent"), id: "u1", in: .profiles)
        }

        let count = await client.callCount
        #expect(error == .aborted(reason: "contention"))
        #expect(count == 4, "un essai initial plus trois reprises")
    }

    @Test("une politique peut refuser une catégorie")
    func policyCanOptOutOfACategory() async throws {
        let (store, client) = makeRetryingStore(
            policy: FirestoreRetryPolicy(
                maxRetries: 3,
                retries: [.unavailable],          // la contention n'est pas rejouée
                backoff: .constant(.milliseconds(1))
            )
        )
        await client.failNextCalls(2, with: .aborted(reason: "contention"))

        _ = await #expect(throws: FirestoreError.self) {
            try await store.setDocument(profile("Florent"), id: "u1", in: .profiles)
        }

        let count = await client.callCount
        #expect(count == 1)
    }

    @Test("sans reprise, le premier échec remonte")
    func noneMeansNone() async throws {
        let (store, client) = makeRetryingStore(policy: .disabled)
        await client.failNextCalls(1, with: .aborted(reason: "contention"))

        _ = await #expect(throws: FirestoreError.self) {
            try await store.setDocument(profile("Florent"), id: "u1", in: .profiles)
        }

        let count = await client.callCount
        #expect(count == 1)
    }

    @Test("un lot entier est rejoué, et reste atomique")
    func batchIsRetriedAsAWhole() async throws {
        let (store, client) = makeRetryingStore()
        await client.failNextCalls(1, with: .aborted(reason: "contention"))

        try await store.batch { batch in
            batch.set(profile("Alice"), id: "a", in: .profiles)
            batch.set(profile("Bob"), id: "b", in: .profiles)
        }

        let all = try await store.documents(in: .profiles)
        #expect(Set(all.map(\.id)) == ["a", "b"])
    }

    @Test("le backoff exponentiel croît, et le jitter le rend imprévisible")
    func backoffGrows() {
        let steady = Backoff.exponential(base: .milliseconds(100), jitter: false)

        #expect(steady.delay(forAttempt: 1) == .milliseconds(100))
        #expect(steady.delay(forAttempt: 2) == .milliseconds(200))
        #expect(steady.delay(forAttempt: 3) == .milliseconds(400))

        // Sans aléa, deux écritures qui se sont percutées reviendraient exactement
        // ensemble et se percuteraient à nouveau.
        let jittered = Backoff.exponential(base: .milliseconds(100), jitter: true)
        let samples = (0..<20).map { _ in jittered.delay(forAttempt: 2) }
        #expect(Set(samples).count > 1, "le jitter introduit bien de la variation")
        #expect(samples.allSatisfy { $0 >= .milliseconds(200) && $0 <= .milliseconds(300) })
    }
}
