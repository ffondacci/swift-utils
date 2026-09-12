import Foundation

/// Le backend fichier : un document JSON unique, sur disque.
///
/// Le document est un dictionnaire `clé → octets`. Il est chargé une fois, modifié en
/// mémoire, puis réécrit **atomiquement** à chaque changement. L'acteur sérialise les
/// accès, ce qui rend le cycle lire-modifier-réécrire sûr sans verrou explicite.
///
/// > Note : les valeurs apparaissent en base64 dans le fichier. C'est le prix de la
/// > séparation des couches — le backend ne manipule que des octets et ne peut pas savoir
/// > qu'ils contiennent, ici, du JSON. Le fichier est un conteneur, pas un fichier de
/// > configuration qu'on édite à la main.
public actor JSONFileBackend: PersistenceBackend {

    private let fileURL: URL

    /// Le document, ou `nil` tant qu'il n'a pas été lu. La lecture disque n'a lieu qu'une
    /// fois, au premier accès.
    private var document: [String: Data]?

    /// - Parameter fileURL: le fichier à utiliser. Son dossier parent est créé au besoin,
    ///   à la première écriture.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Un backend rangé dans le dossier Application Support de l'app.
    ///
    /// - Parameters:
    ///   - name: le nom du fichier, sans extension.
    ///   - subdirectory: le sous-dossier d'Application Support qui l'accueille.
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
            fileURL: base
                .appending(path: subdirectory, directoryHint: .isDirectory)
                .appending(path: "\(name).json", directoryHint: .notDirectory)
        )
    }

    public func read(_ key: StorageKey) throws(PersistenceError) -> Data? {
        try loadedDocument(for: key.rawValue)[key.rawValue]
    }

    public func write(_ data: Data, for key: StorageKey) throws(PersistenceError) {
        var document = try loadedDocument(for: key.rawValue)
        document[key.rawValue] = data
        try persist(document, key: key.rawValue)
    }

    public func remove(_ key: StorageKey) throws(PersistenceError) {
        var document = try loadedDocument(for: key.rawValue)
        guard document.removeValue(forKey: key.rawValue) != nil else { return }
        do {
            try persist(document, key: key.rawValue)
        } catch {
            throw .removeFailed(key: key.rawValue, reason: error.description)
        }
    }

    public func contains(_ key: StorageKey) throws(PersistenceError) -> Bool {
        try loadedDocument(for: key.rawValue)[key.rawValue] != nil
    }

    public func removeAll() throws(PersistenceError) {
        document = [:]
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw .clearFailed(reason: "suppression de \(fileURL.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    // MARK: - Disque

    /// Le document en mémoire, lu depuis le disque au premier appel.
    ///
    /// - Parameter key: uniquement pour situer une éventuelle erreur de lecture.
    private func loadedDocument(for key: String) throws(PersistenceError) -> [String: Data] {
        if let document { return document }

        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            document = [:]
            return [:]
        }

        let raw: Data
        do {
            raw = try Data(contentsOf: fileURL)
        } catch {
            throw .readFailed(key: key, reason: "lecture de \(fileURL.lastPathComponent) — \(error.localizedDescription)")
        }

        do {
            let decoded = try JSONDecoder().decode([String: Data].self, from: raw)
            document = decoded
            return decoded
        } catch {
            throw .readFailed(
                key: key,
                reason: "\(fileURL.lastPathComponent) est illisible — \(error.localizedDescription)"
            )
        }
    }

    private func persist(_ document: [String: Data], key: String) throws(PersistenceError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]

        let raw: Data
        do {
            raw = try encoder.encode(document)
        } catch {
            throw .writeFailed(key: key, reason: "sérialisation du document — \(error.localizedDescription)")
        }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // .atomic : un crash en cours d'écriture laisse l'ancien document intact
            // plutôt qu'un fichier tronqué.
            try raw.write(to: fileURL, options: [.atomic])
        } catch {
            throw .writeFailed(key: key, reason: "écriture de \(fileURL.lastPathComponent) — \(error.localizedDescription)")
        }

        self.document = document
    }
}
