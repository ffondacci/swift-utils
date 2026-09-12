import Foundation

/// Ce qui accompagne une erreur réseau pour qu'on puisse la diagnostiquer sans rejouer la
/// requête.
///
/// Les en-têtes sont assainis : tout ce qui ressemble à un jeton est remplacé par sa
/// longueur. Une erreur finit souvent dans un log, et un log finit souvent ailleurs.
public struct NetworkErrorContext: Sendable, Equatable {

    public let method: String
    public let url: String
    public let requestHeaders: [String: String]
    public let statusCode: Int?
    /// Tronqué à 2 000 caractères : au-delà, on ne diagnostique plus, on inonde.
    public let responseBody: String?

    public init(
        method: String,
        url: String,
        requestHeaders: [String: String] = [:],
        statusCode: Int? = nil,
        responseBody: String? = nil
    ) {
        self.method = method
        self.url = url
        self.requestHeaders = requestHeaders.mapValues(Self.sanitized)
        self.statusCode = statusCode
        self.responseBody = responseBody.map { String($0.prefix(2_000)) }
    }

    /// Remplace une valeur qui ressemble à un secret par sa seule longueur.
    static func sanitized(_ value: String) -> String {
        let lowered = value.lowercased()
        let looksLikeSecret = lowered.hasPrefix("bearer ")
            || lowered.hasPrefix("basic ")
            || value.count > 64
        return looksLikeSecret ? "<\(value.count) caractères masqués>" : value
    }
}

extension NetworkErrorContext: CustomStringConvertible {
    public var description: String {
        var parts = ["\(method) \(url)"]
        if let statusCode { parts.append("HTTP \(statusCode)") }
        if let responseBody, !responseBody.isEmpty { parts.append("corps : \(responseBody)") }
        return parts.joined(separator: " · ")
    }
}

/// Toutes les erreurs que `SUNetworking` peut produire.
///
/// Comme pour `SUPersistence`, chaque cas porte de quoi comprendre ce qui s'est passé —
/// ici le verbe, l'URL, le statut et le corps de réponse. Les erreurs d'`URLSession` sont
/// traduites en remontant, jamais propagées telles quelles.
public enum NetworkError: Error, Sendable, Equatable {

    /// L'URL n'a pas pu être construite — service inconnu de l'environnement, ou chemin
    /// impossible à composer.
    case invalidURL(service: String, path: String)

    /// La requête n'a pas abouti au niveau transport : pas de réseau, DNS, TLS, timeout.
    case transportFailed(context: NetworkErrorContext, reason: String)

    /// Le serveur a répondu hors de la plage 2xx.
    case httpFailed(context: NetworkErrorContext)

    /// Le serveur a refusé la requête **en donnant lui-même la raison**, dans le format
    /// d'erreur de son API.
    ///
    /// C'est ce qu'un endpoint produit quand il sait lire l'enveloppe d'erreur de son
    /// service — une Cloud Function `onCall` rend
    /// `{"error":{"message":…,"status":"PERMISSION_DENIED"}}`. Le message et le code
    /// arrivent alors typés, au lieu d'un corps JSON à parser à la main.
    case serviceFailed(context: NetworkErrorContext, code: String, message: String)

    /// La réponse est arrivée mais ne correspond pas au type attendu.
    case decodingFailed(context: NetworkErrorContext, reason: String)

    /// Le corps de la requête n'a pas pu être sérialisé. L'erreur précède l'envoi : rien
    /// n'a atteint le réseau.
    case encodingFailed(reason: String)

    /// L'endpoint exige une authentification et aucun jeton n'a pu être obtenu.
    case tokenUnavailable(reason: String)

    /// Le serveur a refusé le jeton, y compris après rafraîchissement.
    case unauthorized(context: NetworkErrorContext)

    /// La tâche a été annulée. Ce n'est pas un échec : c'est en général une vue qui
    /// disparaît.
    case cancelled

    /// Le statut HTTP, quand l'erreur en porte un.
    public var statusCode: Int? {
        switch self {
        case let .transportFailed(context, _),
             let .httpFailed(context),
             let .decodingFailed(context, _),
             let .unauthorized(context):
            context.statusCode
        case let .serviceFailed(context, _, _):
            context.statusCode
        case .invalidURL, .encodingFailed, .tokenUnavailable, .cancelled:
            nil
        }
    }

    /// Le contexte, quand l'erreur en porte un.
    public var context: NetworkErrorContext? {
        switch self {
        case let .transportFailed(context, _),
             let .httpFailed(context),
             let .decodingFailed(context, _),
             let .unauthorized(context):
            context
        case let .serviceFailed(context, _, _):
            context
        case .invalidURL, .encodingFailed, .tokenUnavailable, .cancelled:
            nil
        }
    }

    /// Indique si réessayer a une chance d'aboutir, indépendamment de la politique de
    /// retry — une erreur de décodage ne s'arrangera jamais toute seule.
    public var isRetryable: Bool {
        switch self {
        case .transportFailed:
            true
        case let .httpFailed(context):
            context.statusCode.map { $0 == 429 || (500..<600).contains($0) } ?? false
        case let .serviceFailed(context, _, _):
            // Le serveur a nommé la raison : c'est une décision, pas un incident.
            // Seul un 429 ou un 5xx mérite d'être rejoué.
            context.statusCode.map { $0 == 429 || (500..<600).contains($0) } ?? false
        case .invalidURL, .decodingFailed, .encodingFailed, .tokenUnavailable, .unauthorized, .cancelled:
            false
        }
    }
}

extension NetworkError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .invalidURL(service, path):
            "URL impossible à construire pour le service « \(service) » et le chemin « \(path) »"
        case let .transportFailed(context, reason):
            "Requête non aboutie — \(reason) · \(context)"
        case let .httpFailed(context):
            "Le serveur a refusé la requête · \(context)"
        case let .serviceFailed(context, code, message):
            "\(code) — \(message) · \(context)"
        case let .decodingFailed(context, reason):
            "Réponse illisible — \(reason) · \(context)"
        case let .encodingFailed(reason):
            "Corps de requête impossible à sérialiser — \(reason)"
        case let .tokenUnavailable(reason):
            "Authentification impossible — \(reason)"
        case let .unauthorized(context):
            "Jeton refusé par le serveur · \(context)"
        case .cancelled:
            "Requête annulée"
        }
    }
}
