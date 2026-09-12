import Foundation

/// La correspondance entre un service et son URL de base.
///
/// C'est le seul endroit où une URL est écrite. Les endpoints ne portent qu'un chemin,
/// ce qui permet de basculer staging ↔ production en changeant un objet, sans toucher à
/// une seule déclaration d'endpoint.
///
/// ```swift
/// extension APIEnvironment {
///     static let production = APIEnvironment([
///         .account: URL(string: "https://api.lensy.app/v1")!,
///         .catalog: URL(string: "https://catalog.lensy.app")!,
///     ])
/// }
/// ```
public struct APIEnvironment: Sendable {

    private let baseURLs: [APIService: URL]

    public init(_ baseURLs: [APIService: URL]) {
        self.baseURLs = baseURLs
    }

    /// L'URL de base d'un service, ou `nil` s'il n'est pas déclaré ici.
    public func baseURL(for service: APIService) -> URL? {
        baseURLs[service]
    }

    /// Les services déclarés — pratique pour vérifier au démarrage qu'on n'en a oublié
    /// aucun.
    public var services: Set<APIService> { Set(baseURLs.keys) }
}
