import Foundation
import Testing
@testable import SUFirestore

/// Filtrer, ordonner, limiter.
@MainActor
@Suite("Requêtes")
struct FirestoreQueryTests {

    private func seeded() async throws -> FirestoreStore {
        let (store, _) = makeStore()
        try await store.setDocument(profile("Alice", visits: 50, premium: true, tags: ["pro", "beta"]), id: "a", in: .profiles)
        try await store.setDocument(profile("Bob", visits: 5, tags: ["beta"]), id: "b", in: .profiles)
        try await store.setDocument(profile("Carol", visits: 20, premium: true), id: "c", in: .profiles)
        return store
    }

    @Test("sans filtre, toute la collection remonte")
    func unrestrictedReturnsEverything() async throws {
        let store = try await seeded()

        let all = try await store.documents(in: .profiles)
        #expect(all.count == 3)
    }

    @Test("une collection vide rend un tableau vide")
    func emptyCollection() async throws {
        let (store, _) = makeStore()

        let all = try await store.documents(in: .profiles)
        #expect(all.isEmpty)
    }

    @Test("un filtre d'égalité sélectionne")
    func equalityFilter() async throws {
        let store = try await seeded()

        let premium = try await store.documents(in: .profiles) { $0.where("premium", .isEqualTo, true) }

        #expect(premium.count == 2)
        #expect(Set(premium.map(\.id)) == ["a", "c"])
    }

    @Test("un filtre d'inégalité sélectionne")
    func comparisonFilter() async throws {
        let store = try await seeded()

        let actifs = try await store.documents(in: .profiles) { $0.where("visits", .isGreaterThan, 10) }

        #expect(Set(actifs.map(\.id)) == ["a", "c"])
    }

    @Test("arrayContains cherche dans un tableau")
    func arrayContains() async throws {
        let store = try await seeded()

        let beta = try await store.documents(in: .profiles) { $0.where("tags", .arrayContains, "beta") }

        #expect(Set(beta.map(\.id)) == ["a", "b"])
    }

    @Test("isIn accepte plusieurs valeurs")
    func isIn() async throws {
        let store = try await seeded()

        let some = try await store.documents(in: .profiles) { $0.where("name", .isIn, ["Alice", "Bob"]) }

        #expect(Set(some.map(\.id)) == ["a", "b"])
    }

    @Test("les filtres se cumulent")
    func filtersCombine() async throws {
        let store = try await seeded()

        let result = try await store.documents(in: .profiles) {
            $0.where("premium", .isEqualTo, true).where("visits", .isLessThan, 30)
        }

        #expect(result.map(\.id) == ["c"])
    }

    @Test("le tri respecte l'ordre demandé")
    func ordering() async throws {
        let store = try await seeded()

        let ascending = try await store.documents(in: .profiles) { $0.order(by: "visits") }
        let descending = try await store.documents(in: .profiles) { $0.order(by: "visits", descending: true) }

        #expect(ascending.map(\.id) == ["b", "c", "a"])
        #expect(descending.map(\.id) == ["a", "c", "b"])
    }

    @Test("la limite s'applique après le tri")
    func limitAppliesAfterOrdering() async throws {
        let store = try await seeded()

        let top = try await store.documents(in: .profiles) {
            $0.order(by: "visits", descending: true).limit(to: 2)
        }

        #expect(top.map(\.id) == ["a", "c"])
    }

    @Test("une requête est une description, pas un objet mutable")
    func queryIsAValue() {
        let base = DocumentQuery().where("a", .isEqualTo, 1)
        let derived = base.where("b", .isEqualTo, 2)

        #expect(base.filters.count == 1, "la requête d'origine n'a pas bougé")
        #expect(derived.filters.count == 2)
    }

    @Test("les documents d'une sous-collection ne polluent pas la collection parente")
    func subcollectionsAreNotMixedIn() async throws {
        let store = try await seeded()
        let posts: CollectionPath<Post> = CollectionPath<Profile>.profiles.document("a").collection("posts")
        try await store.setDocument(Post(title: "x"), at: posts.document("p1"))

        let profiles = try await store.documents(in: .profiles)
        #expect(profiles.count == 3, "le post ne compte pas comme un profil")
    }
}
