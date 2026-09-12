import Foundation

/// Toutes les erreurs que `SUFirestore` peut produire.
///
/// Les codes de Firestore sont traduits en cas nommés : une app doit pouvoir distinguer
/// « pas le droit » de « pas de réseau » sans comparer des entiers, et réagir
/// différemment — l'un demande de reconnecter l'utilisateur, l'autre d'attendre.
public enum FirestoreError: Error, Sendable, Equatable {

    /// Les règles de sécurité ont refusé l'opération.
    case permissionDenied(path: String, reason: String)

    /// Le document n'existe pas, alors que l'opération l'exigeait.
    ///
    /// Une simple lecture d'un document absent rend `nil` et ne jette pas — ce cas
    /// concerne les opérations qui exigent son existence, comme une mise à jour partielle.
    case notFound(path: String)

    /// Le document existe déjà, alors que l'opération exigeait le contraire.
    case alreadyExists(path: String)

    /// Le service est injoignable — hors ligne, réseau coupé, backend indisponible.
    ///
    /// C'est le seul cas qui vaille vraiment la peine d'être réessayé plus tard.
    case unavailable(reason: String)

    /// L'utilisateur n'est pas authentifié, ou son jeton a expiré.
    case unauthenticated(reason: String)

    /// L'opération a dépassé son délai.
    case deadlineExceeded(path: String)

    /// L'état ne permet pas l'opération.
    ///
    /// Le cas le plus fréquent est **un index manquant**. Firestore glisse alors l'URL de
    /// création dans son message ; elle est extraite dans `indexURL` pour qu'on n'ait pas
    /// à la pêcher à la main dans la console.
    case failedPrecondition(reason: String, indexURL: URL?)

    /// Trop d'écritures, quota dépassé.
    case resourceExhausted(reason: String)

    /// La transaction a été abandonnée, généralement à cause d'une écriture concurrente.
    case aborted(reason: String)

    /// La requête est mal formée — champ inconnu, combinaison de filtres interdite.
    case invalidArgument(path: String, reason: String)

    /// Le document existe mais ne correspond plus au type attendu. Signature d'un
    /// changement de schéma.
    case decodingFailed(path: String, type: String, reason: String)

    /// La valeur n'a pas pu être convertie pour l'écriture.
    case encodingFailed(path: String, type: String, reason: String)

    /// L'opération a été annulée.
    case cancelled

    /// Un code que le module ne connaît pas encore. Il porte le code brut pour qu'on
    /// puisse au moins le diagnostiquer.
    case unknown(path: String?, code: Int, reason: String)

    /// Le chemin concerné, quand l'erreur en vise un.
    public var path: String? {
        switch self {
        case let .permissionDenied(path, _),
             let .notFound(path),
             let .alreadyExists(path),
             let .deadlineExceeded(path),
             let .invalidArgument(path, _),
             let .decodingFailed(path, _, _),
             let .encodingFailed(path, _, _):
            path
        case let .unknown(path, _, _):
            path
        case .unavailable, .unauthenticated, .failedPrecondition,
             .resourceExhausted, .aborted, .cancelled:
            nil
        }
    }

    /// Indique si réessayer plus tard a une chance d'aboutir.
    ///
    /// Un refus des règles de sécurité ou un document mal formé ne s'arrangeront jamais
    /// tout seuls ; une coupure réseau, si.
    public var isRetryable: Bool {
        switch self {
        case .unavailable, .deadlineExceeded, .resourceExhausted, .aborted:
            true
        case .permissionDenied, .notFound, .alreadyExists, .unauthenticated,
             .failedPrecondition, .invalidArgument, .decodingFailed,
             .encodingFailed, .cancelled, .unknown:
            false
        }
    }

    /// Indique si l'utilisateur doit se reconnecter.
    public var requiresReauthentication: Bool {
        switch self {
        case .unauthenticated: true
        case .permissionDenied, .notFound, .alreadyExists, .unavailable, .deadlineExceeded,
             .failedPrecondition, .resourceExhausted, .aborted, .invalidArgument,
             .decodingFailed, .encodingFailed, .cancelled, .unknown:
            false
        }
    }
}

extension FirestoreError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .permissionDenied(path, reason):
            "Accès refusé sur « \(path) » : \(reason)"
        case let .notFound(path):
            "Document introuvable : « \(path) »"
        case let .alreadyExists(path):
            "Le document « \(path) » existe déjà"
        case let .unavailable(reason):
            "Firestore injoignable : \(reason)"
        case let .unauthenticated(reason):
            "Non authentifié : \(reason)"
        case let .deadlineExceeded(path):
            "Délai dépassé sur « \(path) »"
        case let .failedPrecondition(reason, indexURL):
            indexURL.map { "Précondition non remplie : \(reason) — créer l'index : \($0.absoluteString)" }
                ?? "Précondition non remplie : \(reason)"
        case let .resourceExhausted(reason):
            "Quota dépassé : \(reason)"
        case let .aborted(reason):
            "Opération abandonnée : \(reason)"
        case let .invalidArgument(path, reason):
            "Requête invalide sur « \(path) » : \(reason)"
        case let .decodingFailed(path, type, reason):
            "Décodage de \(type) impossible depuis « \(path) » : \(reason)"
        case let .encodingFailed(path, type, reason):
            "Encodage de \(type) impossible vers « \(path) » : \(reason)"
        case .cancelled:
            "Opération annulée"
        case let .unknown(path, code, reason):
            path.map { "Erreur Firestore \(code) sur « \($0) » : \(reason)" }
                ?? "Erreur Firestore \(code) : \(reason)"
        }
    }
}
