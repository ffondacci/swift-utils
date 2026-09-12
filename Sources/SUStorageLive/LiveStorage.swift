#if Firebase
import Foundation
import FirebaseStorage
import SUStorage

/// L'adaptateur qui parle au vrai Firebase Storage.
///
/// C'est le **seul** type du dépôt qui importe `FirebaseStorage`, et il ne le laisse pas
/// franchir sa frontière : aucune `StorageReference`, aucune `StorageMetadata` n'apparaît
/// dans sa surface publique.
///
/// > Important : `FirebaseApp.configure()` doit avoir eu lieu **avant** de construire ce
/// > client. Ce module ne configure rien — `configure()` doit être appelé exactement une
/// > fois, et seule l'app peut le garantir.
public struct LiveStorage: StorageClient {

    // `Storage` n'est pas annoté `Sendable` : le SDK compile en mode Swift 5, donc aucun
    // de ses types ne l'est. L'instance est immuable et ne sert qu'à dériver des
    // références ; le SDK sérialise lui-même ses transferts.
    //
    // À réévaluer le jour où Firebase annotera ses types.
    nonisolated(unsafe) private let storage: Storage

    /// - Parameters:
    ///   - bucket: l'URL `gs://…` d'un bucket autre que celui par défaut du projet.
    ///   - emulator: pointer un émulateur local au lieu du vrai service.
    public init(bucket: String? = nil, emulator: Emulator? = nil) {
        let storage = bucket.map { Storage.storage(url: $0) } ?? Storage.storage()
        if let emulator {
            storage.useEmulator(withHost: emulator.host, port: emulator.port)
        }
        self.storage = storage
    }

    public struct Emulator: Sendable, Equatable {
        public var host: String
        public var port: Int

        public init(host: String = "127.0.0.1", port: Int = 9199) {
            self.host = host
            self.port = port
        }
    }

    // MARK: - Téléversement

    public func upload(
        fileAt source: URL,
        to path: ObjectPath,
        metadata: UploadMetadata?,
        onProgress: ProgressHandler?
    ) async throws(StorageFailure) -> ObjectMetadata {
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
            throw .localFileUnreadable(url: source, reason: "fichier absent")
        }
        do {
            let result = try await storage.reference(withPath: path.path).putFileAsync(
                from: source,
                metadata: Self.metadata(from: metadata),
                onProgress: Self.forward(onProgress)
            )
            return Self.translate(result, at: path)
        } catch {
            throw Self.translate(error, path: path.path)
        }
    }

    public func upload(
        _ data: Data,
        to path: ObjectPath,
        metadata: UploadMetadata?,
        onProgress: ProgressHandler?
    ) async throws(StorageFailure) -> ObjectMetadata {
        do {
            let result = try await storage.reference(withPath: path.path).putDataAsync(
                data,
                metadata: Self.metadata(from: metadata),
                onProgress: Self.forward(onProgress)
            )
            return Self.translate(result, at: path)
        } catch {
            throw Self.translate(error, path: path.path)
        }
    }

    // MARK: - Téléchargement

    public func download(
        _ path: ObjectPath,
        to destination: URL,
        onProgress: ProgressHandler?
    ) async throws(StorageFailure) -> URL {
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw .transferFailed(path: path.path, reason: error.localizedDescription)
        }
        do {
            return try await storage.reference(withPath: path.path).writeAsync(
                toFile: destination,
                onProgress: Self.forward(onProgress)
            )
        } catch {
            throw Self.translate(error, path: path.path)
        }
    }

    public func data(
        _ path: ObjectPath,
        maximumSize: Int,
        onProgress: ProgressHandler?
    ) async throws(StorageFailure) -> Data {
        do {
            let data = try await storage.reference(withPath: path.path).data(maxSize: Int64(maximumSize))
            onProgress?(TransferProgress(completed: data.count, total: data.count))
            return data
        } catch {
            throw Self.translate(error, path: path.path)
        }
    }

    // MARK: - Sans transfert

    public func metadata(of path: ObjectPath) async throws(StorageFailure) -> ObjectMetadata {
        do {
            return Self.translate(
                try await storage.reference(withPath: path.path).getMetadata(),
                at: path
            )
        } catch {
            throw Self.translate(error, path: path.path)
        }
    }

    public func list(
        in folder: StorageFolder,
        limit: Int,
        pageToken: String?
    ) async throws(StorageFailure) -> ObjectListing {
        let reference = storage.reference(withPath: folder.path)
        do {
            let result: StorageListResult
            if let pageToken {
                result = try await reference.list(maxResults: Int64(limit), pageToken: pageToken)
            } else {
                result = try await reference.list(maxResults: Int64(limit))
            }
            // `list` ne rend que les noms : les métadonnées demanderaient un appel par
            // objet. On rend donc une taille nulle, et l'appelant demande le détail de ce
            // qui l'intéresse.
            return ObjectListing(
                objects: result.items.map {
                    ObjectMetadata(path: ObjectPath($0.fullPath), size: 0)
                },
                folders: result.prefixes.map { StorageFolder($0.fullPath) },
                nextPageToken: result.pageToken
            )
        } catch {
            throw Self.translate(error, path: folder.path)
        }
    }

    public func delete(_ path: ObjectPath) async throws(StorageFailure) {
        do {
            try await storage.reference(withPath: path.path).delete()
        } catch {
            throw Self.translate(error, path: path.path)
        }
    }

    public func downloadURL(for path: ObjectPath) async throws(StorageFailure) -> URL {
        do {
            return try await storage.reference(withPath: path.path).downloadURL()
        } catch {
            throw Self.translate(error, path: path.path)
        }
    }

    // MARK: - Conversions

    private static func forward(_ onProgress: ProgressHandler?) -> ((Progress?) -> Void)? {
        guard let onProgress else { return nil }
        return { progress in
            guard let progress else { return }
            onProgress(TransferProgress(
                completed: Int(progress.completedUnitCount),
                // `totalUnitCount` vaut -1 quand le total est inconnu : une barre
                // déterminée serait alors un mensonge.
                total: progress.totalUnitCount > 0 ? Int(progress.totalUnitCount) : nil
            ))
        }
    }

    private static func metadata(from metadata: UploadMetadata?) -> StorageMetadata? {
        guard let metadata else { return nil }
        let result = StorageMetadata()
        result.contentType = metadata.contentType
        result.cacheControl = metadata.cacheControl
        if !metadata.custom.isEmpty { result.customMetadata = metadata.custom }
        return result
    }

    private static func translate(_ metadata: StorageMetadata, at path: ObjectPath) -> ObjectMetadata {
        ObjectMetadata(
            path: path,
            size: Int(metadata.size),
            contentType: metadata.contentType,
            eTag: metadata.md5Hash,
            created: metadata.timeCreated,
            updated: metadata.updated,
            custom: metadata.customMetadata ?? [:]
        )
    }

    private static func translate(_ error: any Error, path: String) -> StorageFailure {
        let nsError = error as NSError
        let reason = nsError.localizedDescription

        guard let code = StorageErrorCode(rawValue: nsError.code) else {
            return .unknown(path: path, code: nsError.code, reason: reason)
        }

        return switch code {
        case .objectNotFound, .bucketNotFound, .projectNotFound: .notFound(path: path)
        case .unauthorized: .unauthorized(path: path, reason: reason)
        case .unauthenticated: .unauthenticated(reason: reason)
        case .quotaExceeded: .quotaExceeded(reason: reason)
        case .retryLimitExceeded: .retryLimitExceeded(path: path)
        case .nonMatchingChecksum: .checksumMismatch(path: path)
        case .downloadSizeExceeded: .tooLargeForMemory(path: path, limit: 0)
        case .cancelled: .cancelled
        default: .unknown(path: path, code: nsError.code, reason: reason)
        }
    }
}
#endif
