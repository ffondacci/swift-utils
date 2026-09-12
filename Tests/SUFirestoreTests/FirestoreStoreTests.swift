import Foundation
import Testing
@testable import SUFirestore

/// Lire, écrire, fusionner, supprimer — la surface que l'app touche.
@MainActor
@Suite("Store Firestore")
struct FirestoreStoreTests {

    @Test("un document absent rend nil plutôt qu'une erreur")
    func missingDocumentIsNil() async throws {
        let (store, _) = makeStore()

        let loaded = try await store.document("jamais", in: .profiles)
        #expect(loaded == nil)
    }

    @Test("un document écrit se relit à l'identique")
    func roundTrip() async throws {
        let (store, _) = makeStore()
        let florent = profile("Florent", visits: 3, premium: true, tags: ["a", "b"])

        try await store.setDocument(florent, id: "u1", in: .profiles)

        let loaded = try await store.document("u1", in: .profiles)
        #expect(loaded == florent)
    }

    @Test("sans merge, l'écriture remplace le document entier")
    func setReplacesWholeDocument() async throws {
        let (store, _) = makeStore()
        try await store.setDocument(profile("Avant", visits: 99, tags: ["x"]), id: "u1", in: .profiles)

        try await store.setDocument(profile("Après"), id: "u1", in: .profiles)

        let loaded = try await store.document("u1", in: .profiles)
        #expect(loaded?.name == "Après")
        #expect(loaded?.visits == 0, "le champ absent de la nouvelle valeur a disparu")
        #expect(loaded?.tags.isEmpty == true)
    }

    @Test("avec merge, seuls les champs fournis changent")
    func mergeKeepsUntouchedFields() async throws {
        let (store, client) = makeStore()
        try await client.seed(profile("Florent", visits: 42, premium: true), at: "profiles/u1")

        // Un type partiel : seuls ses champs sont écrits.
        struct VisitsOnly: Codable, Sendable { var visits: Int }
        try await store.setDocument(
            VisitsOnly(visits: 43),
            at: DocumentPath<VisitsOnly>("profiles/u1"),
            merge: true
        )

        let loaded = try await store.document("u1", in: .profiles)
        #expect(loaded?.visits == 43, "le champ fourni est à jour")
        #expect(loaded?.name == "Florent", "les autres champs survivent")
        #expect(loaded?.premium == true)
    }

    @Test("la mise à jour exige que le document existe")
    func updateRequiresExistence() async throws {
        let (store, _) = makeStore()

        let error = await #expect(throws: FirestoreError.self) {
            try await store.updateDocument(["visits": 1], id: "jamais", in: .profiles)
        }

        #expect(error == .notFound(path: "profiles/jamais"))
    }

    @Test("la mise à jour ne touche qu'aux champs nommés")
    func updateTouchesNamedFieldsOnly() async throws {
        let (store, _) = makeStore()
        try await store.setDocument(profile("Florent", visits: 1, premium: true), id: "u1", in: .profiles)

        try await store.updateDocument(["visits": 5], id: "u1", in: .profiles)

        let loaded = try await store.document("u1", in: .profiles)
        #expect(loaded?.visits == 5)
        #expect(loaded?.name == "Florent")
        #expect(loaded?.premium == true)
    }

    @Test("supprimer un document le rend absent")
    func deleteRemoves() async throws {
        let (store, _) = makeStore()
        try await store.setDocument(profile("Florent"), id: "u1", in: .profiles)

        try await store.deleteDocument(id: "u1", in: .profiles)

        let loaded = try await store.document("u1", in: .profiles)
        #expect(loaded == nil)
    }

    @Test("supprimer un document absent n'est pas une erreur")
    func deleteMissingSucceeds() async throws {
        let (store, _) = makeStore()
        try await store.deleteDocument(id: "jamais", in: .profiles)
    }

    @Test("un document illisible remonte une erreur, pas un nil silencieux")
    func corruptedDocumentThrows() async throws {
        let (store, client) = makeStore()
        try await client.seed(Post(title: "je ne suis pas un profil"), at: "profiles/u1")

        let error = await #expect(throws: FirestoreError.self) {
            try await store.document("u1", in: .profiles)
        }

        guard case let .decodingFailed(path, type, _) = error else {
            Issue.record("attendu .decodingFailed, reçu \(String(describing: error))")
            return
        }
        #expect(path == "profiles/u1")
        #expect(type == "Profile")
    }

    @Test("l'erreur est retenue pour être affichée, et le compteur revient à zéro")
    func errorIsRetained() async throws {
        let (store, client) = makeStore()
        await client.failNextCall(with: .permissionDenied(path: "profiles/u1", reason: "règles"))

        _ = await #expect(throws: FirestoreError.self) {
            try await store.document("u1", in: .profiles)
        }

        #expect(store.lastError?.path == "profiles/u1")
        #expect(store.inFlightCount == 0)
        #expect(store.isLoading == false)

        store.clearLastError()
        #expect(store.lastError == nil)
    }

    @Test("les sous-collections sont des chemins comme les autres")
    func subcollections() async throws {
        let (store, _) = makeStore()
        let posts: CollectionPath<Post> = CollectionPath<Profile>.profiles.document("u1").collection("posts")

        try await store.setDocument(Post(title: "bonjour"), at: posts.document("p1"))

        let loaded = try await store.document(at: posts.document("p1"))
        #expect(posts.path == "profiles/u1/posts")
        #expect(loaded?.title == "bonjour")
    }
}
