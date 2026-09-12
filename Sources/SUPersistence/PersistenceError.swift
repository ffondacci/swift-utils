import Foundation

/// Toutes les erreurs que `SUPersistence` peut produire.
///
/// Chaque cas porte de quoi diagnostiquer sans debugger : la clé concernée, le type en
/// jeu quand il y en a un, et la raison sous-jacente déjà mise en forme. Les erreurs des
/// couches basses (`FileManager`, `JSONDecoder`) sont traduites en remontant, jamais
/// propagées telles quelles.
public enum PersistenceError: Error, Equatable, Sendable {

    /// La lecture du support de stockage a échoué.
    case readFailed(key: String, reason: String)

    /// L'écriture sur le support de stockage a échoué.
    case writeFailed(key: String, reason: String)

    /// La suppression d'une clé a échoué.
    case removeFailed(key: String, reason: String)

    /// L'effacement complet du stockage a échoué.
    case clearFailed(reason: String)

    /// La valeur n'a pas pu être encodée vers sa représentation stockée.
    case encodingFailed(key: String, type: String, reason: String)

    /// Les octets relus n'ont pas pu être décodés vers le type attendu.
    ///
    /// C'est le cas typique d'un changement de schéma : la donnée est là, mais elle ne
    /// correspond plus au type courant.
    case decodingFailed(key: String, type: String, reason: String)

    /// Le support de stockage lui-même est inutilisable — suite `UserDefaults`
    /// introuvable, répertoire non créable.
    case storageUnavailable(reason: String)

    /// La clé concernée, quand l'erreur en vise une.
    public var key: String? {
        switch self {
        case let .readFailed(key, _),
             let .writeFailed(key, _),
             let .removeFailed(key, _),
             let .encodingFailed(key, _, _),
             let .decodingFailed(key, _, _):
            key
        case .clearFailed, .storageUnavailable:
            nil
        }
    }
}

extension PersistenceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .readFailed(key, reason):
            "Lecture impossible pour la clé « \(key) » : \(reason)"
        case let .writeFailed(key, reason):
            "Écriture impossible pour la clé « \(key) » : \(reason)"
        case let .removeFailed(key, reason):
            "Suppression impossible pour la clé « \(key) » : \(reason)"
        case let .clearFailed(reason):
            "Effacement du stockage impossible : \(reason)"
        case let .encodingFailed(key, type, reason):
            "Encodage de \(type) impossible pour la clé « \(key) » : \(reason)"
        case let .decodingFailed(key, type, reason):
            "Décodage de \(type) impossible pour la clé « \(key) » : \(reason)"
        case let .storageUnavailable(reason):
            "Stockage indisponible : \(reason)"
        }
    }
}
