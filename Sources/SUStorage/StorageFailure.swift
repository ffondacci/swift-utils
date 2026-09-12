import Foundation

/// Toutes les erreurs que `SUStorage` peut produire.
///
/// > Le nom rompt avec `PersistenceError`, `NetworkError` et `FirestoreError` pour une
/// > raison : `StorageError` existe déjà dans `FirebaseStorage`. Une app qui importe les
/// > deux aurait eu une ambiguïté à chaque usage — le même piège que `FirestoreQuery` et
/// > `WriteBatch` côté Firestore.
///
/// Les codes du SDK sont traduits en cas nommés : une app doit pouvoir distinguer « ce
/// fichier n'existe pas » de « vous n'avez pas le droit » sans comparer des entiers, parce
/// qu'elle n'en fait pas du tout la même chose.
public enum StorageFailure: Error, Sendable, Equatable {

    /// L'objet n'existe pas.
    case notFound(path: String)

    /// Les règles de sécurité ont refusé l'opération.
    case unauthorized(path: String, reason: String)

    /// L'utilisateur n'est pas authentifié, ou son jeton a expiré.
    case unauthenticated(reason: String)

    /// Le quota du projet est dépassé.
    case quotaExceeded(reason: String)

    /// Le transfert a échoué au niveau réseau — coupure, serveur injoignable.
    case transferFailed(path: String, reason: String)

    /// Le SDK a épuisé ses tentatives.
    ///
    /// Distinct de ``transferFailed`` : ici il a déjà réessayé, donc insister tout de
    /// suite ne servira à rien.
    case retryLimitExceeded(path: String)

    /// Les octets reçus ne correspondent pas à leur empreinte. Le fichier est corrompu.
    case checksumMismatch(path: String)

    /// Le fichier dépasse la taille maximale acceptée pour un chargement en mémoire.
    ///
    /// Signe qu'il fallait télécharger vers un fichier plutôt que vers un `Data`.
    case tooLargeForMemory(path: String, limit: Int)

    /// Le fichier local à téléverser est introuvable ou illisible.
    case localFileUnreadable(url: URL, reason: String)

    /// Le transfert a été annulé.
    case cancelled

    /// Un code que le module ne connaît pas encore, avec de quoi le diagnostiquer.
    case unknown(path: String?, code: Int, reason: String)

    /// Le chemin concerné, quand l'erreur en vise un.
    public var path: String? {
        switch self {
        case let .notFound(path),
             let .unauthorized(path, _),
             let .transferFailed(path, _),
             let .retryLimitExceeded(path),
             let .checksumMismatch(path),
             let .tooLargeForMemory(path, _):
            path
        case let .unknown(path, _, _):
            path
        case .unauthenticated, .quotaExceeded, .localFileUnreadable, .cancelled:
            nil
        }
    }

    /// Indique si réessayer plus tard a une chance d'aboutir.
    public var isRetryable: Bool {
        switch self {
        case .transferFailed, .quotaExceeded:
            true
        case .notFound, .unauthorized, .unauthenticated, .retryLimitExceeded,
             .checksumMismatch, .tooLargeForMemory, .localFileUnreadable,
             .cancelled, .unknown:
            false
        }
    }

    /// Indique si l'utilisateur doit se reconnecter.
    public var requiresReauthentication: Bool {
        if case .unauthenticated = self { true } else { false }
    }
}

extension StorageFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .notFound(path): "Fichier introuvable : « \(path) »"
        case let .unauthorized(path, reason): "Accès refusé sur « \(path) » : \(reason)"
        case let .unauthenticated(reason): "Non authentifié : \(reason)"
        case let .quotaExceeded(reason): "Quota dépassé : \(reason)"
        case let .transferFailed(path, reason): "Transfert interrompu sur « \(path) » : \(reason)"
        case let .retryLimitExceeded(path): "Tentatives épuisées sur « \(path) »"
        case let .checksumMismatch(path): "Empreinte incorrecte sur « \(path) » — fichier corrompu"
        case let .tooLargeForMemory(path, limit):
            "« \(path) » dépasse \(limit) octets — téléchargez vers un fichier plutôt qu'en mémoire"
        case let .localFileUnreadable(url, reason): "Fichier local illisible (\(url.lastPathComponent)) : \(reason)"
        case .cancelled: "Transfert annulé"
        case let .unknown(path, code, reason):
            path.map { "Erreur de stockage \(code) sur « \($0) » : \(reason)" }
                ?? "Erreur de stockage \(code) : \(reason)"
        }
    }
}
