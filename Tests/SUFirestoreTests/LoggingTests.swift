import Foundation
import SULogger
import Testing
@testable import SUFirestore

/// Une contention qui se résout toute seule est invisible sans trace — et c'est
/// exactement ce qu'on veut voir quand une app « rame parfois ».
@MainActor
@Suite("Traces Firestore")
struct FirestoreLoggingTests {

    private func withLog(_ body: (CollectingDestination) async throws -> Void) async throws {
        let collector = CollectingDestination()
        // Portée plutôt que global : les suites tournent en parallèle, et une
        // configuration task-local ne gêne personne.
        try await Log.withConfiguration(LogConfiguration(destinations: [collector])) {
            try await body(collector)
        }
    }

    @Test("une écriture laisse une trace avec son chemin")
    func writeIsTraced() async throws {
        try await withLog { collector in
            let (store, _) = makeStore()

            try await store.setDocument(profile("Florent"), id: "u1", in: .profiles)

            #expect(collector.entries(for: .firestore).isEmpty == false)
            #expect(collector.contains("profiles/u1"))
        }
    }

    @Test("un merge est distingué d'un remplacement")
    func mergeIsVisible() async throws {
        try await withLog { collector in
            let (store, _) = makeStore()

            try await store.setDocument(profile("Florent"), id: "u1", in: .profiles, merge: true)

            #expect(collector.contains("merge"), "la distinction qui fait perdre des données doit se voir")
        }
    }

    @Test("un échec est tracé en erreur, avec le chemin et le code")
    func failureIsTracedAsError() async throws {
        try await withLog { collector in
            let (store, client) = makeStore()
            await client.failNextCall(with: .permissionDenied(path: "profiles/u1", reason: "règles"))

            _ = await #expect(throws: FirestoreError.self) {
                try await store.document("u1", in: .profiles)
            }

            let errors = collector.entries(atLeast: .error)
            #expect(errors.count == 1)
            #expect(errors.first?.category == .firestore)
            #expect(errors.first?.message.contains("profiles/u1") == true)
            #expect(errors.first?.message.contains("refusé") == true)
        }
    }

    @Test("une reprise sur contention est tracée en avertissement")
    func retryIsTracedAsWarning() async throws {
        try await withLog { collector in
            let client = InMemoryFirestore()
            let store = FirestoreStore(
                client: RetryingFirestore(
                    wrapping: client,
                    policy: FirestoreRetryPolicy(maxRetries: 3, backoff: .constant(.milliseconds(1)))
                )
            )
            await client.failNextCalls(2, with: .aborted(reason: "contention"))

            try await store.setDocument(profile("Florent"), id: "u1", in: .profiles)

            let warnings = collector.entries.filter { $0.level == .warning }
            #expect(warnings.count == 2, "une trace par reprise")
            #expect(warnings.first?.message.contains("reprise 1/3") == true)
        }
    }

    @Test("un lot annonce son nombre d'écritures")
    func batchSizeIsTraced() async throws {
        try await withLog { collector in
            let (store, _) = makeStore()

            try await store.batch { batch in
                batch.set(profile("A"), id: "a", in: .profiles)
                batch.set(profile("B"), id: "b", in: .profiles)
            }

            #expect(collector.contains("lot de 2 écritures"))
        }
    }

    @Test("les catégories séparent bien le local du distant")
    func localAndRemoteAreSeparate() async throws {
        try await withLog { collector in
            let (store, _) = makeStore()
            try await store.setDocument(profile("Florent"), id: "u1", in: .profiles)

            #expect(collector.entries(for: .firestore).isEmpty == false)
            #expect(collector.entries(for: .persistence).isEmpty, "Firestore n'est pas du stockage local")
        }
    }
}
