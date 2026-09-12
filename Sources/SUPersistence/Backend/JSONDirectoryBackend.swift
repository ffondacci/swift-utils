import Foundation

/// Un fichier JSON par clé, dans un dossier.
///
/// C'est le pendant de ``JSONFileBackend`` pour les gros volumes. Le document unique
/// réécrit tout à chaque écriture et charge tout en mémoire — parfait pour des réglages,
/// intenable pour un catalogue de plusieurs milliers d'entrées. Ici chaque écriture ne
/// touche qu'un fichier.
///
/// Les deux honorent le même contrat et passent les mêmes tests : le choix est une
/// question de volume, pas de fonctionnalité.
public actor JSONDirectoryBackend: PersistenceBackend {

    /// Les caractères gardés tels quels dans un nom de fichier. Tout le reste est
    /// pourcent-encodé, ce qui neutralise au passage les `/` et donc toute tentative de
    /// sortir du dossier.
    private static let safeCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_."))

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Un dossier dans Application Support.
    public init(
        named name: String,
        subdirectory: String = "SUPersistence"
    ) throws(PersistenceError) {
        let base: URL
        do {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw .storageUnavailable(
                reason: "dossier Application Support inaccessible — \(error.localizedDescription)"
            )
        }
        self.init(
            directory: base
                .appending(path: subdirectory, directoryHint: .isDirectory)
                .appending(path: name, directoryHint: .isDirectory)
        )
    }

    public func read(_ key: StorageKey) throws(PersistenceError) -> Data? {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw .readFailed(key: key.rawValue, reason: error.localizedDescription)
        }
    }

    public func write(_ data: Data, for key: StorageKey) throws(PersistenceError) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: key), options: [.atomic])
        } catch {
            throw .writeFailed(key: key.rawValue, reason: error.localizedDescription)
        }
    }

    public func remove(_ key: StorageKey) throws(PersistenceError) {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw .removeFailed(key: key.rawValue, reason: error.localizedDescription)
        }
    }

    public func contains(_ key: StorageKey) throws(PersistenceError) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: key).path(percentEncoded: false))
    }

    public func removeAll() throws(PersistenceError) {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw .clearFailed(reason: error.localizedDescription)
        }
    }

    public func keys(withPrefix prefix: String) throws(PersistenceError) -> [StorageKey] {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return []
        }
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        } catch {
            throw .readFailed(key: prefix, reason: "dossier illisible — \(error.localizedDescription)")
        }
        return contents
            .compactMap { key(fromFileName: $0.lastPathComponent) }
            .filter { $0.rawValue.hasPrefix(prefix) }
    }

    // MARK: - Noms de fichiers

    private func fileURL(for key: StorageKey) -> URL {
        let encoded = key.rawValue
            .addingPercentEncoding(withAllowedCharacters: Self.safeCharacters) ?? key.rawValue
        return directory.appending(path: "\(encoded).json", directoryHint: .notDirectory)
    }

    private func key(fromFileName name: String) -> StorageKey? {
        guard name.hasSuffix(".json") else { return nil }
        let encoded = String(name.dropLast(".json".count))
        guard let decoded = encoded.removingPercentEncoding else { return nil }
        return StorageKey(decoded)
    }
}
