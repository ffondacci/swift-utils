import Foundation
import Testing
@testable import SUFirestore

/// Parcourir une collection par pages, sans tout charger.
@MainActor
@Suite("Pagination")
struct PaginationTests {

    private func seeded() async throws -> FirestoreStore {
        let (store, _) = makeStore()
        for (index, name) in ["Alice", "Bob", "Carol", "David", "Eve"].enumerated() {
            try await store.setDocument(profile(name, visits: index), id: name.lowercased(), in: .profiles)
        }
        return store
    }

    @Test("startAfter exclut le point de reprise")
    func startAfterExcludesTheCursor() async throws {
        let store = try await seeded()

        let after = try await store.documents(in: .profiles) {
            $0.order(by: "name").start(after: ["Bob"])
        }

        #expect(after.map(\.value.name) == ["Carol", "David", "Eve"])
    }

    @Test("startAt inclut le point de reprise")
    func startAtIncludesTheCursor() async throws {
        let store = try await seeded()

        let from = try await store.documents(in: .profiles) {
            $0.order(by: "name").start(at: ["Bob"])
        }

        #expect(from.map(\.value.name) == ["Bob", "Carol", "David", "Eve"])
    }

    @Test("endBefore et endAt bornent l'autre extrémité")
    func endBounds() async throws {
        let store = try await seeded()

        let before = try await store.documents(in: .profiles) {
            $0.order(by: "name").end(before: ["Carol"])
        }
        let upTo = try await store.documents(in: .profiles) {
            $0.order(by: "name").end(at: ["Carol"])
        }

        #expect(before.map(\.value.name) == ["Alice", "Bob"])
        #expect(upTo.map(\.value.name) == ["Alice", "Bob", "Carol"])
    }

    @Test("le motif de pagination parcourt toute la collection sans doublon ni oubli")
    func fullPaginationWalk() async throws {
        let store = try await seeded()
        var collected: [String] = []
        var cursor: QueryValue?

        while true {
            let page = try await store.documents(in: .profiles) {
                var query = $0.order(by: "name").limit(to: 2)
                if let cursor { query = query.start(after: [cursor]) }
                return query
            }
            guard !page.isEmpty else { break }
            collected.append(contentsOf: page.map(\.value.name))
            cursor = page.last.map { .string($0.value.name) }
        }

        #expect(collected == ["Alice", "Bob", "Carol", "David", "Eve"])
        #expect(Set(collected).count == collected.count, "aucun doublon")
    }

    @Test("la pagination suit le sens du tri")
    func paginationFollowsDescendingOrder() async throws {
        let store = try await seeded()

        let page = try await store.documents(in: .profiles) {
            $0.order(by: "visits", descending: true).start(after: [3]).limit(to: 2)
        }

        #expect(page.map(\.value.name) == ["Carol", "Bob"])
    }

    @Test("la limite s'applique après le curseur")
    func limitAppliesAfterCursor() async throws {
        let store = try await seeded()

        let page = try await store.documents(in: .profiles) {
            $0.order(by: "name").start(after: ["Alice"]).limit(to: 2)
        }

        #expect(page.map(\.value.name) == ["Bob", "Carol"])
    }
}
