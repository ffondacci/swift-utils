import Foundation

/// Le chemin d'un dossier dans le bucket.
///
/// **Le module n'en déclare aucun** — comme les clés de `SUPersistence` et les chemins de
/// `SUFirestore`, ils appartiennent au domaine de l'app.
///
/// ```swift
/// extension StorageFolder {
///     static let images: StorageFolder = "images"
///     static let exports: StorageFolder = "exports"
/// }
///
/// try await storage.upload(fileAt: local, to: .images.object("u1/photo.jpg"))
/// ```
public struct StorageFolder: Sendable, Hashable, ExpressibleByStringLiteral {

    /// Le chemin, segments séparés par `/`, sans barre de tête ni de queue.
    public let path: String

    public init(_ path: String) {
        self.path = Self.normalized(path)
    }

    public init(stringLiteral value: String) { self.init(value) }

    /// Un objet de ce dossier.
    public func object(_ name: String) -> ObjectPath {
        ObjectPath(path.isEmpty ? name : "\(path)/\(name)")
    }

    /// Un sous-dossier.
    public func folder(_ name: String) -> StorageFolder {
        StorageFolder(path.isEmpty ? name : "\(path)/\(name)")
    }

    /// La racine du bucket.
    public static let root = StorageFolder("")

    static func normalized(_ path: String) -> String {
        path.split(separator: "/").joined(separator: "/")
    }
}

/// Le chemin d'un objet dans le bucket.
public struct ObjectPath: Sendable, Hashable, ExpressibleByStringLiteral {

    public let path: String

    public init(_ path: String) {
        self.path = StorageFolder.normalized(path)
    }

    public init(stringLiteral value: String) { self.init(value) }

    /// Le nom du fichier, sans son dossier.
    public var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Le dossier qui le contient.
    public var folder: StorageFolder {
        StorageFolder(path.split(separator: "/").dropLast().joined(separator: "/"))
    }
}

/// Ce qu'on sait d'un objet sans l'avoir téléchargé.
public struct ObjectMetadata: Sendable, Equatable {

    public let path: ObjectPath

    /// La taille en octets. C'est ce qu'on regarde avant de décider d'un chargement en
    /// mémoire.
    public let size: Int

    public let contentType: String?

    /// L'empreinte du contenu. Elle change à chaque écriture, donc elle sert aussi de clé
    /// de cache : même `eTag`, même octets.
    public let eTag: String?

    public let created: Date?
    public let updated: Date?

    /// Les métadonnées maison attachées à l'objet — dimensions d'une image, identifiant
    /// d'auteur, ce qu'on veut.
    public let custom: [String: String]

    public init(
        path: ObjectPath,
        size: Int,
        contentType: String? = nil,
        eTag: String? = nil,
        created: Date? = nil,
        updated: Date? = nil,
        custom: [String: String] = [:]
    ) {
        self.path = path
        self.size = size
        self.contentType = contentType
        self.eTag = eTag
        self.created = created
        self.updated = updated
        self.custom = custom
    }
}

/// Une page de listing.
public struct ObjectListing: Sendable, Equatable {

    /// Les objets de la page.
    public let objects: [ObjectMetadata]

    /// Les sous-dossiers rencontrés.
    public let folders: [StorageFolder]

    /// Le jeton à repasser pour la page suivante. `nil` quand il n'y en a plus.
    public let nextPageToken: String?

    public init(
        objects: [ObjectMetadata],
        folders: [StorageFolder] = [],
        nextPageToken: String? = nil
    ) {
        self.objects = objects
        self.folders = folders
        self.nextPageToken = nextPageToken
    }

    public var isEmpty: Bool { objects.isEmpty && folders.isEmpty }
}

/// L'avancement d'un transfert.
public struct TransferProgress: Sendable, Equatable {

    /// Les octets déjà transférés.
    public let completed: Int

    /// Le total attendu. `nil` quand le serveur ne l'annonce pas — auquel cas il n'y a pas
    /// de fraction, et une barre de progression indéterminée est la seule honnête.
    public let total: Int?

    public init(completed: Int, total: Int?) {
        self.completed = completed
        self.total = total
    }

    /// Entre 0 et 1, ou `nil` si le total est inconnu.
    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }

    public var isFinished: Bool {
        guard let total else { return false }
        return completed >= total
    }
}

/// Ce qu'on reçoit à chaque avancement.
public typealias ProgressHandler = @Sendable (TransferProgress) -> Void
