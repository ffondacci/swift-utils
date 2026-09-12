import Foundation
import Testing
@testable import SUPersistence

/// Le contrat que **tout** backend doit honorer, à l'identique.
///
/// Chaque test tourne sur les trois supports. C'est ce qui prouve la promesse du module :
/// changer de stockage ne change pas le comportement. Un backend ajouté demain — SQLite,
/// SwiftData — rejoint cette suite et doit passer sans qu'une seule assertion bouge.
@Suite("Contrat de backend")
struct PersistenceBackendConformanceTests {

    @Test("relire ce qu'on vient d'écrire rend les mêmes octets", arguments: BackendFixture.allCases)
    func roundTrip(fixture: BackendFixture) async throws {
        try await withBackend(fixture) { backend in
            let payload = Data("bonjour".utf8)
            try await backend.write(payload, for: "greeting")

            let reread = try await backend.read("greeting")
            #expect(reread == payload)
        }
    }

    @Test("une clé jamais écrite rend nil", arguments: BackendFixture.allCases)
    func missingKeyIsNil(fixture: BackendFixture) async throws {
        try await withBackend(fixture) { backend in
            let value = try await backend.read("jamais-ecrite")
            #expect(value == nil)
        }
    }

    @Test("réécrire une clé remplace sa valeur", arguments: BackendFixture.allCases)
    func overwrite(fixture: BackendFixture) async throws {
        try await withBackend(fixture) { backend in
            try await backend.write(Data([1]), for: "k")
            try await backend.write(Data([2]), for: "k")

            let value = try await backend.read("k")
            #expect(value == Data([2]))
        }
    }

    @Test("contains distingue une clé écrite d'une clé absente", arguments: BackendFixture.allCases)
    func contains(fixture: BackendFixture) async throws {
        try await withBackend(fixture) { backend in
            let beforeWrite = try await backend.contains("k")
            #expect(beforeWrite == false)

            try await backend.write(Data([1]), for: "k")

            let afterWrite = try await backend.contains("k")
            #expect(afterWrite == true)
        }
    }

    @Test("supprimer une clé la rend absente", arguments: BackendFixture.allCases)
    func remove(fixture: BackendFixture) async throws {
        try await withBackend(fixture) { backend in
            try await backend.write(Data([1]), for: "k")
            try await backend.remove("k")

            let value = try await backend.read("k")
            let present = try await backend.contains("k")
            #expect(value == nil)
            #expect(present == false)
        }
    }

    @Test("supprimer une clé absente n'est pas une erreur", arguments: BackendFixture.allCases)
    func removeMissingKeySucceeds(fixture: BackendFixture) async throws {
        try await withBackend(fixture) { backend in
            try await backend.remove("jamais-ecrite")
        }
    }

    @Test("removeAll vide toutes les clés écrites", arguments: BackendFixture.allCases)
    func removeAll(fixture: BackendFixture) async throws {
        try await withBackend(fixture) { backend in
            try await backend.write(Data([1]), for: "a")
            try await backend.write(Data([2]), for: "b")

            try await backend.removeAll()

            let first = try await backend.read("a")
            let second = try await backend.read("b")
            #expect(first == nil)
            #expect(second == nil)
        }
    }

    @Test("écrire après removeAll fonctionne encore", arguments: BackendFixture.allCases)
    func writeAfterRemoveAll(fixture: BackendFixture) async throws {
        try await withBackend(fixture) { backend in
            try await backend.write(Data([1]), for: "a")
            try await backend.removeAll()
            try await backend.write(Data([9]), for: "a")

            let value = try await backend.read("a")
            #expect(value == Data([9]))
        }
    }

    @Test("l'énumération par préfixe ne rend que les clés concernées", arguments: BackendFixture.allCases)
    func keysWithPrefix(fixture: BackendFixture) async throws {
        try await withBackend(fixture) { backend in
            try await backend.write(Data([1]), for: "collection/profiles/a")
            try await backend.write(Data([2]), for: "collection/profiles/b")
            try await backend.write(Data([3]), for: "collection/scores/z")
            try await backend.write(Data([4]), for: "reglage")

            let profiles = try await backend.keys(withPrefix: "collection/profiles/")
            let all = try await backend.keys(withPrefix: "")

            #expect(Set(profiles.map(\.rawValue)) == ["collection/profiles/a", "collection/profiles/b"])
            #expect(all.count == 4)
        }
    }

    @Test("un préfixe sans correspondance rend une liste vide", arguments: BackendFixture.allCases)
    func keysWithUnmatchedPrefix(fixture: BackendFixture) async throws {
        try await withBackend(fixture) { backend in
            try await backend.write(Data([1]), for: "a")

            let keys = try await backend.keys(withPrefix: "jamais/")
            #expect(keys.isEmpty)
        }
    }

    @Test("une clé supprimée disparaît de l'énumération", arguments: BackendFixture.allCases)
    func removedKeyLeavesEnumeration(fixture: BackendFixture) async throws {
        try await withBackend(fixture) { backend in
            try await backend.write(Data([1]), for: "x/1")
            try await backend.remove("x/1")

            let keys = try await backend.keys(withPrefix: "x/")
            #expect(keys.isEmpty)
        }
    }

    @Test("cinquante écritures concurrentes aboutissent toutes", arguments: BackendFixture.allCases)
    func concurrentWrites(fixture: BackendFixture) async throws {
        try await withBackend(fixture) { backend in
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<50 {
                    group.addTask {
                        try? await backend.write(Data([UInt8(index)]), for: StorageKey("k\(index)"))
                    }
                }
            }

            for index in 0..<50 {
                let value = try await backend.read(StorageKey("k\(index)"))
                #expect(value == Data([UInt8(index)]))
            }
        }
    }
}
