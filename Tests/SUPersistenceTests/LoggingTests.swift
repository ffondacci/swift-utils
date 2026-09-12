import Foundation
import SULogger
import Testing
@testable import SUPersistence

/// Ce qui se passe dans le stockage doit être traçable — surtout les échecs, qui sont
/// invisibles autrement.
@MainActor
@Suite("Traces de persistance")
struct PersistenceLoggingTests {

    private func withLog(_ body: (CollectingDestination) async throws -> Void) async throws {
        let collector = CollectingDestination()
        // Portée plutôt que global : les suites tournent en parallèle, et une
        // configuration task-local ne gêne personne.
        try await Log.withConfiguration(LogConfiguration(destinations: [collector])) {
            try await body(collector)
        }
    }

    @Test("une écriture laisse une trace avec sa clé")
    func writeIsTraced() async throws {
        try await withLog { collector in
            let store = PersistenceStore.inMemory()

            try await store.save(42, for: .launchCount)

            let traces = collector.entries(for: .persistence)
            #expect(traces.isEmpty == false)
            #expect(collector.contains("launchCount"))
        }
    }

    @Test("une clé absente est tracée comme telle, pas en erreur")
    func absenceIsNotAnError() async throws {
        try await withLog { collector in
            let store = PersistenceStore.inMemory()

            _ = try await store.stored(.launchCount)

            #expect(collector.entries(atLeast: .warning).isEmpty, "une absence n'est pas un échec")
            #expect(collector.contains("absente"))
        }
    }

    @Test("un décodage impossible est tracé en erreur")
    func decodingFailureIsTracedAsError() async throws {
        try await withLog { collector in
            let backend = InMemoryBackend(storage: ["profile": Data("pas du json".utf8)])
            let store = PersistenceStore(repository: CodableRepository(backend: backend))

            _ = await #expect(throws: PersistenceError.self) {
                try await store.load(.profile)
            }

            let errors = collector.entries(atLeast: .error)
            #expect(errors.count == 1)
            #expect(errors.first?.category == .persistence)
            #expect(errors.first?.message.contains("profile") == true)
            #expect(errors.first?.message.contains("Profile") == true, "le type attendu aussi")
        }
    }

    @Test("un effacement complet est tracé plus haut qu'un debug")
    func removeAllIsNoteworthy() async throws {
        try await withLog { collector in
            let store = PersistenceStore.inMemory()

            try await store.removeAll()

            #expect(collector.entries(atLeast: .info).isEmpty == false, "effacer tout mérite mieux qu'un debug")
        }
    }

    @Test("le filtre de catégorie fait taire la persistance sans toucher au reste")
    func categoryFilterSilencesPersistence() async throws {
        let collector = CollectingDestination()

        try await Log.withConfiguration(
            LogConfiguration(categories: [.network], destinations: [collector])
        ) {
            let store = PersistenceStore.inMemory()
            try await store.save(1, for: .launchCount)
        }

        #expect(collector.entries.isEmpty)
    }
}
