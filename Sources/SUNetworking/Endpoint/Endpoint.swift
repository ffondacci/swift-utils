import Foundation

/// Une requête HTTP et la façon de décoder sa réponse.
///
/// **Le module ne déclare aucun endpoint.** Ils appartiennent au domaine de l'app, comme
/// les clés de `SUPersistence` : le module livre le contrat, l'app le remplit. Deux apps
/// ne se coordonnent sur rien.
///
/// ```swift
/// struct FetchProfile: Endpoint {
///     let userID: String
///
///     var service: APIService { .account }
///     var path: String { "/users/\(userID)" }
///     var authentication: AuthRequirement { .required }
///
///     typealias Response = Profile   // décodage JSON par défaut
/// }
/// ```
///
/// Tout a une valeur par défaut sauf `service`, `path` et le type de réponse : un `GET`
/// public tient en trois lignes.
public protocol Endpoint<Response>: Sendable {

    /// Ce que la réponse devient une fois décodée.
    associatedtype Response

    /// Le service appelé. L'`APIEnvironment` en déduit l'URL de base.
    var service: APIService { get }

    /// Le chemin, relatif à l'URL de base du service.
    var path: String { get }

    var method: HTTPMethod { get }
    var query: [URLQueryItem] { get }
    var headers: [String: String] { get }
    var body: RequestBody? { get }
    var authentication: AuthRequirement { get }

    /// Remplace la politique par défaut du client pour ce seul endpoint.
    var policy: RequestPolicy? { get }

    /// Transforme les octets de la réponse en `Response`.
    func decode(_ data: Data) throws -> Response

    /// Traduit une réponse hors 2xx en erreur, quand le service a son propre format
    /// d'erreur.
    ///
    /// Le défaut rend `nil`, et le client produit alors une
    /// ``NetworkError/httpFailed(context:)`` qui porte le corps brut. Redéfinissez-la
    /// quand votre API décrit ses échecs — le message et le code remontent typés au lieu
    /// d'un JSON à parser dans chaque appelant.
    ///
    /// ```swift
    /// func mapError(_ data: Data, statusCode: Int) -> NetworkError? {
    ///     guard let failure = try? JSONDecoder().decode(APIFailure.self, from: data) else {
    ///         return nil   // format inattendu : on laisse le défaut faire
    ///     }
    ///     return .serviceFailed(context: …, code: failure.code, message: failure.message)
    /// }
    /// ```
    func mapError(_ data: Data, statusCode: Int) -> NetworkError?
}

public extension Endpoint {
    var method: HTTPMethod { .get }
    var query: [URLQueryItem] { [] }
    var headers: [String: String] { [:] }
    var body: RequestBody? { nil }
    var authentication: AuthRequirement { .none }
    var policy: RequestPolicy? { nil }
    func mapError(_ data: Data, statusCode: Int) -> NetworkError? { nil }
}

public extension Endpoint where Response: Decodable {
    /// Décodage JSON, dates en ISO 8601. Redéfinissez `decode(_:)` pour un autre format.
    func decode(_ data: Data) throws -> Response {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
    }
}

public extension Endpoint where Response == Data {
    /// Les octets bruts, sans décodage.
    func decode(_ data: Data) throws -> Data { data }
}

public extension Endpoint where Response == Void {
    /// Rien à décoder — pour un `DELETE` ou un endpoint qui répond `204`.
    func decode(_ data: Data) throws {}
}
