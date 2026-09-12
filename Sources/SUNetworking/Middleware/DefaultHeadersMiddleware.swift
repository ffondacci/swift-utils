import Foundation

/// Ajoute des en-têtes à toutes les requêtes — version de l'app, langue, `User-Agent`.
///
/// Un en-tête déjà posé par l'endpoint n'est pas écrasé : le plus spécifique gagne.
public struct DefaultHeadersMiddleware: Middleware {

    private let headers: [String: String]

    public init(_ headers: [String: String]) {
        self.headers = headers
    }

    public func intercept(
        _ context: RequestContext,
        next: @escaping MiddlewareChain
    ) async throws(NetworkError) -> TransportResponse {
        var context = context
        for (name, value) in headers where context.request.headers[name] == nil {
            context.request.headers[name] = value
        }
        return try await next(context)
    }
}
