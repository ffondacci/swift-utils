import Foundation

/// Un stockage qui ne quitte jamais le processus.
///
/// Il honore le même contrat que le vrai, ce qui permet de tester tout le code de
/// téléversement et d'affichage d'une app — y compris la progression — sans réseau, sans
/// bucket, et sans le SDK dans le graphe de dépendances.
public actor InMemoryStorage: StorageClient {

    private struct Stored {
        var data: Data
        var metadata: ObjectMetadata
    }

    private var objects: [String: Stored] = [:]
    private var nextError: StorageFailure?

    /// En combien d'étapes la progression est rapportée. Un test qui vérifie une barre de
    /// progression a besoin de plus d'un point.
    public var progressSteps: Int

    public init(progressSteps: Int = 4) {
        self.progressSteps = max(1, progressSteps)
    }

    /// Sème un objet.
    public func seed(_ data: Data, at path: ObjectPath, contentType: String? = nil) {
        objects[path.path] = Stored(
            data: data,
            metadata: ObjectMetadata(
                path: path,
                size: data.count,
                contentType: contentType,
                eTag: "\(data.hashValue)",
                created: .now,
                updated: .now
            )
        )
    }

    /// Fait échouer le prochain appel.
    public func failNextCall(with error: StorageFailure) {
        nextError = error
    }

    /// Les chemins stockés — pour affirmer dans un test.
    public var storedPaths: [String] { objects.keys.sorted() }

    // MARK: - Écriture

    public func upload(
        fileAt source: URL,
        to path: ObjectPath,
        metadata: UploadMetadata?,
        onProgress: ProgressHandler?
    ) throws(StorageFailure) -> ObjectMetadata {
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw .localFileUnreadable(url: source, reason: error.localizedDescription)
        }
        return try upload(data, to: path, metadata: metadata, onProgress: onProgress)
    }

    public func upload(
        _ data: Data,
        to path: ObjectPath,
        metadata: UploadMetadata?,
        onProgress: ProgressHandler?
    ) throws(StorageFailure) -> ObjectMetadata {
        try consumeScheduledError()
        report(data.count, to: onProgress)

        let stored = ObjectMetadata(
            path: path,
            size: data.count,
            contentType: metadata?.contentType,
            eTag: "\(data.hashValue)",
            created: objects[path.path]?.metadata.created ?? .now,
            updated: .now,
            custom: metadata?.custom ?? [:]
        )
        objects[path.path] = Stored(data: data, metadata: stored)
        return stored
    }

    // MARK: - Lecture

    public func download(
        _ path: ObjectPath,
        to destination: URL,
        onProgress: ProgressHandler?
    ) throws(StorageFailure) -> URL {
        let data = try contents(of: path, onProgress: onProgress)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: [.atomic])
        } catch {
            throw .transferFailed(path: path.path, reason: error.localizedDescription)
        }
        return destination
    }

    public func data(
        _ path: ObjectPath,
        maximumSize: Int,
        onProgress: ProgressHandler?
    ) throws(StorageFailure) -> Data {
        try consumeScheduledError()
        guard let stored = objects[path.path] else { throw .notFound(path: path.path) }
        guard stored.data.count <= maximumSize else {
            throw .tooLargeForMemory(path: path.path, limit: maximumSize)
        }
        report(stored.data.count, to: onProgress)
        return stored.data
    }

    public func metadata(of path: ObjectPath) throws(StorageFailure) -> ObjectMetadata {
        try consumeScheduledError()
        guard let stored = objects[path.path] else { throw .notFound(path: path.path) }
        return stored.metadata
    }

    public func list(
        in folder: StorageFolder,
        limit: Int,
        pageToken: String?
    ) throws(StorageFailure) -> ObjectListing {
        try consumeScheduledError()

        let prefix = folder.path.isEmpty ? "" : "\(folder.path)/"
        var direct: [ObjectMetadata] = []
        var subfolders: Set<String> = []

        for (key, stored) in objects where key.hasPrefix(prefix) {
            let remainder = String(key.dropFirst(prefix.count))
            if remainder.contains("/") {
                // Un objet plus profond signale un sous-dossier, il n'est pas listé ici.
                subfolders.insert(String(remainder.split(separator: "/")[0]))
            } else {
                direct.append(stored.metadata)
            }
        }
        direct.sort { $0.path.path < $1.path.path }

        let start = pageToken.flatMap(Int.init) ?? 0
        let page = Array(direct.dropFirst(start).prefix(limit))
        let consumed = start + page.count

        return ObjectListing(
            objects: page,
            folders: subfolders.sorted().map { folder.folder($0) },
            nextPageToken: consumed < direct.count ? "\(consumed)" : nil
        )
    }

    public func delete(_ path: ObjectPath) throws(StorageFailure) {
        try consumeScheduledError()
        guard objects.removeValue(forKey: path.path) != nil else {
            throw .notFound(path: path.path)
        }
    }

    public func downloadURL(for path: ObjectPath) throws(StorageFailure) -> URL {
        try consumeScheduledError()
        guard objects[path.path] != nil else { throw .notFound(path: path.path) }
        return URL(string: "memory://\(path.path)")!
    }

    // MARK: - Détail

    private func contents(
        of path: ObjectPath,
        onProgress: ProgressHandler?
    ) throws(StorageFailure) -> Data {
        try consumeScheduledError()
        guard let stored = objects[path.path] else { throw .notFound(path: path.path) }
        report(stored.data.count, to: onProgress)
        return stored.data
    }

    /// Rapporte une progression en plusieurs étapes, jusqu'au total.
    private func report(_ total: Int, to onProgress: ProgressHandler?) {
        guard let onProgress else { return }
        for step in 1...progressSteps {
            let completed = total * step / progressSteps
            onProgress(TransferProgress(completed: completed, total: total))
        }
    }

    private func consumeScheduledError() throws(StorageFailure) {
        if let error = nextError {
            nextError = nil
            throw error
        }
    }
}
