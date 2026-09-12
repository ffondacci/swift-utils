import Foundation

/// Le verbe HTTP.
public enum HTTPMethod: String, Sendable, Hashable, CaseIterable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"

    /// Un verbe idempotent peut être rejoué sans changer l'état du serveur. C'est ce qui
    /// décide si une requête est rejouable par défaut : réémettre un `POST` de paiement
    /// après un timeout douteux n'est pas la même chose que réémettre un `GET`.
    public var isIdempotent: Bool {
        switch self {
        case .get, .head, .put, .delete, .options: true
        case .post, .patch: false
        }
    }
}
