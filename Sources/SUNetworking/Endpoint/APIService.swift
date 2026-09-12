import Foundation

/// L'identifiant d'un service distant — une API, pas une URL.
///
/// **Le module n'en déclare aucun.** Comme pour les clés de `SUPersistence`, chaque app
/// déclare les siens, et l'`APIEnvironment` fait la correspondance vers une URL de base.
/// C'est ce qui permet de basculer staging ↔ production sans toucher aux endpoints.
///
/// ```swift
/// extension APIService {
///     static let catalog: APIService = "catalog"
///     static let account: APIService = "account"
/// }
/// ```
public struct APIService: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(value) }
}
