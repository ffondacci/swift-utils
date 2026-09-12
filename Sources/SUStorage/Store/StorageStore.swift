import Foundation
import Observation
import SULogger

/// Un transfert en cours.
public struct Transfer: Sendable, Identifiable, Equatable {

    public enum Kind: Sendable, Equatable {
        case upload
        case download
    }

    public let id: UUID
    public let kind: Kind
    public let path: ObjectPath
    public internal(set) var progress: TransferProgress
}

/// Le point d'entrée du module, et la seule chose que l'app manipule au quotidien.
///
/// Il se place au-dessus du client et n'en expose rien : sa signature ne mentionne ni
/// `StorageReference`, ni `URLSession`. Changer de fournisseur ne change pas une ligne du
/// code appelant — et ça compte, parce que ce choix-là se reprend.
///
/// ## Ce qu'il publie
///
/// Les transferts en cours sont **observés**, avec leur progression. Une vue peut donc
/// afficher un indicateur global sans que personne ne câble quoi que ce soit :
///
/// ```swift
/// @Environment(StorageStore.self) private var storage
///
/// if let transfer = storage.transfers.first {
///     ProgressView(value: transfer.progress.fraction ?? 0)
/// }
/// ```
@MainActor
@Observable
public final class StorageStore {

    @ObservationIgnored private let client: any StorageClient

    /// Les transferts en cours, dans l'ordre de démarrage.
    public private(set) var transfers: [Transfer] = []

    /// La dernière erreur rencontrée, hors annulations.
    ///
    /// Elle n'est pas effacée par un transfert réussi — voir ``clearLastError()``.
    public private(set) var lastError: StorageFailure?

    /// Vrai dès qu'un transfert est en cours.
    public var isTransferring: Bool { !transfers.isEmpty }

    /// La progression cumulée de tous les transferts, ou `nil` si aucun total n'est connu.
    public var overallProgress: Double? {
        let known = transfers.compactMap { transfer -> (Int, Int)? in
            guard let total = transfer.progress.total else { return nil }
            return (transfer.progress.completed, total)
        }
        guard !known.isEmpty else { return nil }
        let completed = known.reduce(0) { $0 + $1.0 }
        let total = known.reduce(0) { $0 + $1.1 }
        return total > 0 ? Double(completed) / Double(total) : nil
    }

    public init(client: any StorageClient) {
        self.client = client
    }

    /// Un store qui ne touche à rien, pour les previews SwiftUI et les tests.
    public static func inMemory() -> StorageStore {
        StorageStore(client: InMemoryStorage())
    }

    // MARK: - Téléversement

    /// Téléverse un fichier local.
    ///
    /// - Parameter onProgress: appelé depuis un contexte quelconque. La progression est de
    ///   toute façon publiée dans ``transfers``, donc ce paramètre ne sert qu'à en faire
    ///   quelque chose de plus.
    @discardableResult
    public func upload(
        fileAt source: URL,
        to path: ObjectPath,
        metadata: UploadMetadata? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws(StorageFailure) -> ObjectMetadata {
        try await tracked(.upload, path, onProgress) { handler throws(StorageFailure) in
            try await client.upload(fileAt: source, to: path, metadata: metadata, onProgress: handler)
        }
    }

    /// Téléverse des octets déjà en mémoire.
    @discardableResult
    public func upload(
        _ data: Data,
        to path: ObjectPath,
        metadata: UploadMetadata? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws(StorageFailure) -> ObjectMetadata {
        try await tracked(.upload, path, onProgress) { handler throws(StorageFailure) in
            try await client.upload(data, to: path, metadata: metadata, onProgress: handler)
        }
    }

    // MARK: - Téléchargement

    /// Télécharge vers un fichier, sans charger le contenu en mémoire.
    @discardableResult
    public func download(
        _ path: ObjectPath,
        to destination: URL,
        onProgress: ProgressHandler? = nil
    ) async throws(StorageFailure) -> URL {
        try await tracked(.download, path, onProgress) { handler throws(StorageFailure) in
            try await client.download(path, to: destination, onProgress: handler)
        }
    }

    /// Télécharge en mémoire, dans la limite donnée.
    ///
    /// - Parameter maximumSize: 10 Mo par défaut. Une photo pleine résolution le dépasse —
    ///   c'est voulu : au-delà, ``download(_:to:onProgress:)`` est la bonne méthode.
    public func data(
        _ path: ObjectPath,
        maximumSize: Int = 10 * 1_024 * 1_024,
        onProgress: ProgressHandler? = nil
    ) async throws(StorageFailure) -> Data {
        try await tracked(.download, path, onProgress) { handler throws(StorageFailure) in
            try await client.data(path, maximumSize: maximumSize, onProgress: handler)
        }
    }

    // MARK: - Sans transfert

    /// Les métadonnées, sans télécharger le contenu.
    public func metadata(of path: ObjectPath) async throws(StorageFailure) -> ObjectMetadata {
        try await report(path) { () async throws(StorageFailure) -> ObjectMetadata in
            try await client.metadata(of: path)
        }
    }

    /// Une page du contenu d'un dossier.
    public func list(
        in folder: StorageFolder,
        limit: Int = 100,
        pageToken: String? = nil
    ) async throws(StorageFailure) -> ObjectListing {
        try await report(nil) { () async throws(StorageFailure) -> ObjectListing in
            try await client.list(in: folder, limit: limit, pageToken: pageToken)
        }
    }

    /// Tout le contenu d'un dossier, page après page.
    ///
    /// - Warning: charge **tout** en mémoire. Pour un dossier de plusieurs milliers de
    ///   fichiers, préférez ``list(in:limit:pageToken:)`` et traitez page par page.
    public func listAll(in folder: StorageFolder, pageSize: Int = 100) async throws(StorageFailure) -> [ObjectMetadata] {
        var all: [ObjectMetadata] = []
        var token: String?
        repeat {
            let page = try await list(in: folder, limit: pageSize, pageToken: token)
            all.append(contentsOf: page.objects)
            token = page.nextPageToken
        } while token != nil
        return all
    }

    /// Supprime un objet.
    public func delete(_ path: ObjectPath) async throws(StorageFailure) {
        try await report(path) { () async throws(StorageFailure) in
            try await client.delete(path)
        }
    }

    /// Une URL de téléchargement.
    public func downloadURL(for path: ObjectPath) async throws(StorageFailure) -> URL {
        try await report(path) { () async throws(StorageFailure) -> URL in
            try await client.downloadURL(for: path)
        }
    }

    /// Oublie la dernière erreur, une fois qu'elle a été montrée.
    public func clearLastError() {
        lastError = nil
    }

    // MARK: - Suivi

    private func tracked<T>(
        _ kind: Transfer.Kind,
        _ path: ObjectPath,
        _ onProgress: ProgressHandler?,
        _ operation: (@escaping ProgressHandler) async throws(StorageFailure) -> T
    ) async throws(StorageFailure) -> T {
        let id = UUID()
        transfers.append(
            Transfer(id: id, kind: kind, path: path, progress: TransferProgress(completed: 0, total: nil))
        )
        defer { transfers.removeAll { $0.id == id } }

        let handler: ProgressHandler = { [weak self] progress in
            onProgress?(progress)
            // La progression arrive d'un contexte quelconque ; l'état observé vit sur le
            // main actor.
            Task { @MainActor [weak self] in self?.record(id, progress) }
        }

        do {
            let result = try await operation(handler)
            Log.debug("\(kind == .upload ? "téléversé" : "téléchargé") \(path.path)", category: .storage)
            return result
        } catch {
            if error != .cancelled { lastError = error }
            Log.error("\(path.path) — \(error)", category: .storage)
            throw error
        }
    }

    /// Les appelants annotent le type d'erreur de leur closure : sans ça, Swift 6.3
    /// l'infère en `any Error` malgré le type du paramètre. Même contournement que dans
    /// `FirestoreStore`.
    private func report<T>(
        _ path: ObjectPath?,
        _ operation: () async throws(StorageFailure) -> T
    ) async throws(StorageFailure) -> T {
        do {
            return try await operation()
        } catch {
            if error != .cancelled { lastError = error }
            Log.error("\(path?.path ?? "listing") — \(error)", category: .storage)
            throw error
        }
    }

    private func record(_ id: UUID, _ progress: TransferProgress) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].progress = progress
    }
}
