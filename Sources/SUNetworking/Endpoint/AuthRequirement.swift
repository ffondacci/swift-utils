import Foundation

/// Ce qu'un endpoint attend en matière d'authentification.
public enum AuthRequirement: Sendable, Hashable {

    /// Aucun jeton n'est joint.
    case none

    /// Un jeton est obligatoire. S'il est indisponible, la requête n'est pas émise —
    /// elle échoue sur `NetworkError.tokenUnavailable` plutôt que de partir sans
    /// identité et de revenir en 401.
    case required

    /// Un jeton est joint s'il est disponible, et la requête part quand même sinon.
    /// Pour les endpoints qui répondent plus richement à un utilisateur connecté.
    case optional
}
