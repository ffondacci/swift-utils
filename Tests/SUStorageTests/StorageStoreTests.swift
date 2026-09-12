import Foundation
import SULogger
import Synchronization
import Testing
@testable import SUStorage

/// Note les avancements. La closure de progression est `@Sendable` : elle ne peut pas
/// muter une variable capturée, et c'est le compilateur qui a raison — elle est appelée
/// depuis un contexte quelconque.
final class ProgressRecorder: Sendable {
    private let storage = Mutex<[TransferProgress]>([])

    var handler: ProgressHandler {
        { progress in self.storage.withLock { $0.append(progress) } }
    }

    var recorded: [TransferProgress] { storage.withLock { $0 } }
}

@MainActor
@Suite("Stockage de fichiers")
struct StorageStoreTests {

    private func temporaryFile(containing text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "su-storage-tests", directoryHint: .isDirectory)
            .appending(path: "\(UUID().uuidString).bin", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
        return url
    }

    private func makeStore() -> (StorageStore, InMemoryStorage) {
        let client = InMemoryStorage()
        return (StorageStore(client: client), client)
    }

    // MARK: - Aller-retour

    @Test("un fichier téléversé se retélécharge à l'identique")
    func fileRoundTrip() async throws {
        let (store, _) = makeStore()
        let source = try temporaryFile(containing: "contenu de la photo")
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = source.deletingLastPathComponent().appending(path: "retour.bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await store.upload(fileAt: source, to: "images/u1/photo.jpg", metadata: .init(contentType: "image/jpeg"))
        _ = try await store.download("images/u1/photo.jpg", to: destination)

        #expect(try Data(contentsOf: destination) == Data("contenu de la photo".utf8))
    }

    @Test("des octets téléversés se relisent à l'identique")
    func dataRoundTrip() async throws {
        let (store, _) = makeStore()
        let payload = Data("vignette".utf8)

        try await store.upload(payload, to: "images/u1/thumb.jpg")

        #expect(try await store.data("images/u1/thumb.jpg") == payload)
    }

    @Test("les métadonnées survivent au téléversement")
    func metadataIsKept() async throws {
        let (store, _) = makeStore()

        let written = try await store.upload(
            Data("x".utf8),
            to: "images/u1/photo.jpg",
            metadata: .init(contentType: "image/jpeg", custom: ["width": "3840"])
        )
        let reread = try await store.metadata(of: "images/u1/photo.jpg")

        #expect(written.contentType == "image/jpeg")
        #expect(reread.custom["width"] == "3840")
        #expect(reread.size == 1)
    }

    @Test("un fichier local absent échoue avant tout transfert")
    func missingLocalFileFails() async throws {
        let (store, client) = makeStore()
        let absent = FileManager.default.temporaryDirectory.appending(path: "jamais-\(UUID()).bin")

        _ = await #expect(throws: StorageFailure.self) {
            try await store.upload(fileAt: absent, to: "images/x.jpg")
        }

        let stored = await client.storedPaths
        #expect(stored.isEmpty)
    }

    // MARK: - Absence et suppression

    @Test("un objet absent remonte notFound, pas un contenu vide")
    func missingObjectThrows() async throws {
        let (store, _) = makeStore()

        let error = await #expect(throws: StorageFailure.self) {
            try await store.data("images/jamais.jpg")
        }

        #expect(error == .notFound(path: "images/jamais.jpg"))
    }

    @Test("supprimer rend l'objet introuvable")
    func deleteRemoves() async throws {
        let (store, _) = makeStore()
        try await store.upload(Data("x".utf8), to: "images/u1/photo.jpg")

        try await store.delete("images/u1/photo.jpg")

        _ = await #expect(throws: StorageFailure.self) {
            try await store.metadata(of: "images/u1/photo.jpg")
        }
    }

    // MARK: - La garde mémoire

    @Test("un fichier trop gros pour la mémoire est refusé plutôt que chargé")
    func oversizedDataIsRefused() async throws {
        let (store, _) = makeStore()
        try await store.upload(Data(repeating: 0, count: 5_000), to: "images/grosse.jpg")

        let error = await #expect(throws: StorageFailure.self) {
            try await store.data("images/grosse.jpg", maximumSize: 1_000)
        }

        // La garde existe pour attraper l'erreur de conception : c'est `download(_:to:)`
        // qu'il fallait appeler.
        guard case let .tooLargeForMemory(_, limit) = error else {
            Issue.record("attendu .tooLargeForMemory, reçu \(String(describing: error))")
            return
        }
        #expect(limit == 1_000)
    }

    // MARK: - Listing

    @Test("le listing sépare les objets d'un dossier de ses sous-dossiers")
    func listSeparatesFoldersFromObjects() async throws {
        let (store, _) = makeStore()
        try await store.upload(Data("a".utf8), to: "images/a.jpg")
        try await store.upload(Data("b".utf8), to: "images/b.jpg")
        try await store.upload(Data("c".utf8), to: "images/2026/c.jpg")

        let listing = try await store.list(in: "images")

        #expect(listing.objects.map(\.path.name) == ["a.jpg", "b.jpg"])
        #expect(listing.folders.map(\.path) == ["images/2026"])
    }

    @Test("le listing se pagine sans doublon ni oubli")
    func listPaginates() async throws {
        let (store, _) = makeStore()
        for index in 0..<5 {
            try await store.upload(Data("x".utf8), to: ObjectPath("images/\(index).jpg"))
        }

        let all = try await store.listAll(in: "images", pageSize: 2)

        #expect(all.count == 5)
        #expect(Set(all.map(\.path.path)).count == 5)
    }

    // MARK: - Progression

    @Test("la progression atteint le total, et le transfert disparaît ensuite")
    func progressCompletesAndClears() async throws {
        let (store, _) = makeStore()
        let payload = Data(repeating: 0, count: 400)
        let recorder = ProgressRecorder()

        try await store.upload(payload, to: "images/u1/photo.jpg", onProgress: recorder.handler)

        let seen = recorder.recorded
        #expect(seen.isEmpty == false)
        #expect(seen.last?.completed == 400)
        #expect(seen.last?.fraction == 1)
        #expect(store.transfers.isEmpty, "le transfert terminé ne reste pas affiché")
        #expect(store.isTransferring == false)
    }

    @Test("un échec est retenu pour affichage, et ne laisse pas de transfert fantôme")
    func failureIsRetainedAndClears() async throws {
        let (store, client) = makeStore()
        await client.failNextCall(with: .quotaExceeded(reason: "plein"))

        _ = await #expect(throws: StorageFailure.self) {
            try await store.upload(Data("x".utf8), to: "images/u1/photo.jpg")
        }

        #expect(store.lastError == .quotaExceeded(reason: "plein"))
        #expect(store.transfers.isEmpty)

        store.clearLastError()
        #expect(store.lastError == nil)
    }

    // MARK: - Chemins

    @Test("les barres superflues ne créent pas de chemins distincts")
    func pathsAreNormalized() async throws {
        let (store, client) = makeStore()

        try await store.upload(Data("x".utf8), to: ObjectPath("/images//u1/photo.jpg/"))

        // Sans normalisation, « images/u1/photo.jpg » et « /images//u1/photo.jpg/ »
        // désigneraient deux objets différents — et l'app ne retrouverait jamais le sien.
        let stored = await client.storedPaths
        #expect(stored == ["images/u1/photo.jpg"])
        #expect(try await store.metadata(of: "images/u1/photo.jpg").size == 1)
    }

    @Test("les échecs sont tracés dans la catégorie storage")
    func failuresAreLogged() async {
        let collector = CollectingDestination()

        await Log.withConfiguration(LogConfiguration(destinations: [collector])) {
            let (store, client) = makeStore()
            await client.failNextCall(with: .notFound(path: "images/x.jpg"))
            _ = try? await store.metadata(of: "images/x.jpg")
        }

        let errors = collector.entries(atLeast: .error)
        #expect(errors.count == 1)
        #expect(errors.first?.category == .storage)
    }
}
