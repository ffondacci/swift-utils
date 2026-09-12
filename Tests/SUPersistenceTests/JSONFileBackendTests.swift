import Foundation
import Testing
@testable import SUPersistence

/// Ce qui est propre au support fichier, et que le contrat commun ne couvre pas :
/// la durabilité entre deux instances, et le fichier lui-même.
@Suite("Backend fichier JSON")
struct JSONFileBackendTests {

    @Test("la donnée survit à une nouvelle instance sur le même fichier")
    func survivesNewInstance() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "store.json")

        let writer = JSONFileBackend(fileURL: fileURL)
        try await writer.write(Data("persisté".utf8), for: "k")

        let reader = JSONFileBackend(fileURL: fileURL)
        let reread = try await reader.read("k")
        #expect(reread == Data("persisté".utf8))
    }

    @Test("le fichier n'est créé qu'à la première écriture")
    func fileIsCreatedLazily() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "store.json")
        let backend = JSONFileBackend(fileURL: fileURL)

        _ = try await backend.read("k")
        #expect(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) == false)

        try await backend.write(Data([1]), for: "k")
        #expect(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) == true)
    }

    @Test("un fichier corrompu remonte une erreur de lecture")
    func corruptedFileThrows() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appending(path: "store.json")
        try Data("{ ceci n'est pas du JSON".utf8).write(to: fileURL)

        let backend = JSONFileBackend(fileURL: fileURL)
        let error = await #expect(throws: PersistenceError.self) {
            try await backend.read("k")
        }

        guard case .readFailed = error else {
            Issue.record("erreur inattendue : \(String(describing: error))")
            return
        }
    }

    @Test("removeAll supprime le fichier du disque")
    func removeAllDeletesFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "store.json")

        let backend = JSONFileBackend(fileURL: fileURL)
        try await backend.write(Data([1]), for: "k")
        try await backend.removeAll()

        #expect(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) == false)
    }
}
