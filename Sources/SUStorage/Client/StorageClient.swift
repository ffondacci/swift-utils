import Foundation

/// Ce qu'on attache à un objet au moment de l'écrire.
public struct UploadMetadata: Sendable, Equatable {

    /// Le type MIME. Il détermine ce que fera un navigateur du fichier, et ce que le CDN
    /// acceptera de mettre en cache — le poser est rarement optionnel en pratique.
    public var contentType: String?

    /// L'en-tête `Cache-Control` servi avec l'objet.
    public var cacheControl: String?

    /// Les métadonnées maison.
    public var custom: [String: String]

    public init(
        contentType: String? = nil,
        cacheControl: String? = nil,
        custom: [String: String] = [:]
    ) {
        self.contentType = contentType
        self.cacheControl = cacheControl
        self.custom = custom
    }
}

/// Ce qui parle réellement au stockage de fichiers.
///
/// Le store ne voit que ce protocole : il ignore s'il s'adresse à Firebase Storage, à un
/// bucket S3 par URL présignée, ou au double en mémoire. C'est ce qui rend le choix du
/// fournisseur réversible — et il l'a déjà été une fois.
public protocol StorageClient: Sendable {

    /// Téléverse un fichier local.
    ///
    /// Depuis un fichier et non depuis un `Data` : une 4K de vingt méga-octets n'a pas à
    /// passer par la mémoire.
    func upload(
        fileAt source: URL,
        to path: ObjectPath,
        metadata: UploadMetadata?,
        onProgress: ProgressHandler?
    ) async throws(StorageFailure) -> ObjectMetadata

    /// Téléverse des octets déjà en mémoire — une vignette, un JSON.
    func upload(
        _ data: Data,
        to path: ObjectPath,
        metadata: UploadMetadata?,
        onProgress: ProgressHandler?
    ) async throws(StorageFailure) -> ObjectMetadata

    /// Télécharge vers un fichier, sans charger le contenu en mémoire.
    func download(
        _ path: ObjectPath,
        to destination: URL,
        onProgress: ProgressHandler?
    ) async throws(StorageFailure) -> URL

    /// Télécharge en mémoire, dans la limite de `maximumSize`.
    ///
    /// - Throws: ``StorageFailure/tooLargeForMemory(path:limit:)`` au-delà. La limite est
    ///   une protection, pas une contrainte : au-delà, c'est ``download(_:to:onProgress:)``
    ///   qu'il fallait appeler.
    func data(
        _ path: ObjectPath,
        maximumSize: Int,
        onProgress: ProgressHandler?
    ) async throws(StorageFailure) -> Data

    /// Les métadonnées, sans télécharger le contenu.
    func metadata(of path: ObjectPath) async throws(StorageFailure) -> ObjectMetadata

    /// Une page du contenu d'un dossier.
    func list(
        in folder: StorageFolder,
        limit: Int,
        pageToken: String?
    ) async throws(StorageFailure) -> ObjectListing

    /// Supprime un objet.
    func delete(_ path: ObjectPath) async throws(StorageFailure)

    /// Une URL publique de téléchargement.
    ///
    /// Chez Firebase elle porte un jeton et reste valable jusqu'à révocation ; ailleurs
    /// elle peut être présignée et expirer. À ne pas traiter comme éternelle.
    func downloadURL(for path: ObjectPath) async throws(StorageFailure) -> URL
}
