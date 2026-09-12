#if Firebase
import Foundation
import SUFirestore
import Testing

/// Les mêmes vérifications que le double en mémoire, mais contre un **vrai** Firestore.
///
/// Un double confirme que le code fait ce qu'on a décidé ; il ne dit pas si ce qu'on a
/// décidé correspond au comportement réel. C'est l'autre question que ces tests posent —
/// et c'est elle qui avait trouvé deux bugs du côté des Cloud Functions.
@MainActor
@Suite("Émulateur — Firestore réel", .enabled(if: emulatorIsRequested), .serialized)
struct LiveFirestoreTests {

    @Test("un document écrit se relit à l'identique")
    func roundTrip() async throws {
        let store = makeBenchStore()
        let profiles = freshProfiles()
        let florent = Profile(name: "Florent", visits: 3, premium: true, tags: ["a", "b"])

        try await store.setDocument(florent, id: "u1", in: profiles)

        let loaded = try await store.document("u1", in: profiles)
        #expect(loaded == florent)
    }

    @Test("un document absent rend nil, pas une erreur")
    func missingIsNil() async throws {
        let store = makeBenchStore()

        let loaded = try await store.document("jamais", in: freshProfiles())
        #expect(loaded == nil)
    }

    @Test("sans merge, l'écriture remplace le document entier")
    func setReplaces() async throws {
        let store = makeBenchStore()
        let profiles = freshProfiles()
        try await store.setDocument(Profile(name: "Avant", visits: 99, tags: ["x"]), id: "u1", in: profiles)

        try await store.setDocument(Profile(name: "Après", visits: 0), id: "u1", in: profiles)

        let loaded = try await store.document("u1", in: profiles)
        #expect(loaded?.visits == 0)
        #expect(loaded?.tags.isEmpty == true)
    }

    @Test("avec merge, les champs non fournis survivent")
    func mergeKeepsFields() async throws {
        let store = makeBenchStore()
        let profiles = freshProfiles()
        try await store.setDocument(Profile(name: "Florent", visits: 42, premium: true), id: "u1", in: profiles)

        struct VisitsOnly: Codable, Sendable { var visits: Int }
        try await store.setDocument(VisitsOnly(visits: 43), at: DocumentPath<VisitsOnly>("\(profiles.path)/u1"), merge: true)

        let loaded = try await store.document("u1", in: profiles)
        #expect(loaded?.visits == 43)
        #expect(loaded?.name == "Florent")
        #expect(loaded?.premium == true)
    }

    @Test("mettre à jour un document absent échoue en notFound")
    func updateMissingFails() async throws {
        let store = makeBenchStore()

        let error = await #expect(throws: FirestoreError.self) {
            try await store.updateDocument(["visits": 1], id: "jamais", in: freshProfiles())
        }

        guard case .notFound = error else {
            Issue.record("attendu .notFound, reçu \(String(describing: error))")
            return
        }
    }

    @Test("filtres, tri et limite donnent bien l'ordre attendu")
    func queries() async throws {
        let store = makeBenchStore()
        let profiles = freshProfiles()
        try await store.setDocument(Profile(name: "Alice", visits: 50, premium: true), id: "a", in: profiles)
        try await store.setDocument(Profile(name: "Bob", visits: 5), id: "b", in: profiles)
        try await store.setDocument(Profile(name: "Carol", visits: 20, premium: true), id: "c", in: profiles)

        let actifs = try await store.documents(in: profiles) {
            $0.where("visits", .isGreaterThan, 10).order(by: "visits", descending: true)
        }

        #expect(actifs.map(\.id) == ["a", "c"])
    }

    @Test("la pagination par curseur parcourt tout sans doublon")
    func pagination() async throws {
        let store = makeBenchStore()
        let profiles = freshProfiles()
        for name in ["Alice", "Bob", "Carol", "David", "Eve"] {
            try await store.setDocument(Profile(name: name, visits: 0), id: name.lowercased(), in: profiles)
        }

        var collected: [String] = []
        var cursor: QueryValue?
        while true {
            let page = try await store.documents(in: profiles) {
                var query = $0.order(by: "name").limit(to: 2)
                if let cursor { query = query.start(after: [cursor]) }
                return query
            }
            guard !page.isEmpty else { break }
            collected.append(contentsOf: page.map(\.value.name))
            cursor = page.last.map { .string($0.value.name) }
        }

        #expect(collected == ["Alice", "Bob", "Carol", "David", "Eve"])
    }

    @Test("un lot est appliqué en entier")
    func batch() async throws {
        let store = makeBenchStore()
        let profiles = freshProfiles()
        try await store.setDocument(Profile(name: "À supprimer", visits: 0), id: "b", in: profiles)

        try await store.batch { batch in
            batch.set(Profile(name: "Nouveau", visits: 1), id: "a", in: profiles)
            batch.delete(id: "b", in: profiles)
        }

        let all = try await store.documents(in: profiles)
        #expect(all.map(\.id) == ["a"])
    }

    @Test("une transaction lit puis écrit en fonction de ce qu'elle a lu")
    func transaction() async throws {
        let store = makeBenchStore()
        let profiles = freshProfiles()
        try await store.setDocument(Profile(name: "Florent", visits: 100), id: "u1", in: profiles)

        try await store.transaction { transaction in
            guard let current = try transaction.document("u1", in: profiles) else { return }
            transaction.set(
                Profile(name: current.name, visits: current.visits - 30),
                id: "u1", in: profiles
            )
        }

        let loaded = try await store.document("u1", in: profiles)
        #expect(loaded?.visits == 70)
    }

    @Test("une transaction abandonnée n'écrit rien")
    func abortedTransactionWritesNothing() async throws {
        let store = makeBenchStore()
        let profiles = freshProfiles()
        try await store.setDocument(Profile(name: "Florent", visits: 100), id: "u1", in: profiles)

        _ = await #expect(throws: FirestoreError.self) {
            try await store.transaction { transaction in
                transaction.set(Profile(name: "Écrasé", visits: 0), id: "u1", in: profiles)
                throw FirestoreError.transactionCancelled(reason: "règle métier")
            }
        }

        let loaded = try await store.document("u1", in: profiles)
        #expect(loaded?.visits == 100, "l'écriture n'a pas été publiée")
    }

    @Test("un incrément s'additionne côté serveur")
    func increment() async throws {
        let store = makeBenchStore()
        let profiles = freshProfiles()
        try await store.setDocument(Profile(name: "Florent", visits: 10), id: "u1", in: profiles)

        try await store.updateDocument(["visits": .increment(5)], id: "u1", in: profiles)
        try await store.updateDocument(["visits": .increment(2)], id: "u1", in: profiles)

        let loaded = try await store.document("u1", in: profiles)
        #expect(loaded?.visits == 17)
    }

    @Test("arrayUnion et arrayRemove agissent côté serveur")
    func arrayOperations() async throws {
        let store = makeBenchStore()
        let profiles = freshProfiles()
        try await store.setDocument(Profile(name: "Florent", visits: 0, tags: ["a"]), id: "u1", in: profiles)

        try await store.updateDocument(["tags": .arrayUnion(["b", "a"])], id: "u1", in: profiles)
        try await store.updateDocument(["tags": .arrayRemove(["a"])], id: "u1", in: profiles)

        let loaded = try await store.document("u1", in: profiles)
        #expect(loaded?.tags == ["b"])
    }

    @Test("supprimer un champ le retire du document")
    func deleteField() async throws {
        let store = makeBenchStore()
        let events = freshEvents()
        try await store.setDocument(Event(name: "e", occurredAt: .now, recordedAt: .now), id: "e1", in: events)

        try await store.updateDocument(["recordedAt": .deleteField], id: "e1", in: events)

        let loaded = try await store.document("e1", in: events)
        #expect(loaded?.recordedAt == nil)
    }

    @Test("une lecture annonce sa provenance")
    func metadata() async throws {
        let store = makeBenchStore()
        let profiles = freshProfiles()
        try await store.setDocument(Profile(name: "Florent", visits: 0), id: "u1", in: profiles)

        let fromServer = try await store.snapshot("u1", in: profiles, source: .server)
        let fromCache = try await store.snapshot("u1", in: profiles, source: .cache)

        #expect(fromServer?.metadata.isFromCache == false)
        #expect(fromCache?.metadata.isFromCache == true)
    }
}
#endif
