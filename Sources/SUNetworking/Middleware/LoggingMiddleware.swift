import Foundation

/// Ce qui arrive à une requête, raconté au journal de l'app.
public enum NetworkEvent: Sendable {

    /// La requête part. `attempt` vaut 0 au premier essai.
    case willSend(method: HTTPMethod, url: String, attempt: Int)

    /// La réponse est revenue, quel que soit son statut.
    case didReceive(method: HTTPMethod, url: String, statusCode: Int, duration: Duration)

    /// La requête n'a pas abouti.
    case didFail(method: HTTPMethod, url: String, error: NetworkError, duration: Duration)
}

/// Où partent les traces réseau.
///
/// **Le module n'embarque pas de logger** — ce serait une dépendance, et le choix du
/// journal appartient à l'app. Elle implémente ce protocole avec ce qu'elle utilise déjà,
/// `OSLog` ou autre.
public protocol NetworkLogger: Sendable {
    func log(_ event: NetworkEvent)
}

/// Raconte chaque requête au `NetworkLogger` fourni, et mesure sa durée.
public struct LoggingMiddleware: Middleware {

    private let logger: any NetworkLogger

    public init(logger: any NetworkLogger) {
        self.logger = logger
    }

    public func intercept(
        _ context: RequestContext,
        next: @escaping MiddlewareChain
    ) async throws(NetworkError) -> TransportResponse {
        let method = context.request.method
        let url = context.request.url.absoluteString
        let clock = ContinuousClock()
        let start = clock.now

        logger.log(.willSend(method: method, url: url, attempt: context.attempt))

        do {
            let response = try await next(context)
            logger.log(.didReceive(
                method: method,
                url: url,
                statusCode: response.statusCode,
                duration: clock.now - start
            ))
            return response
        } catch {
            logger.log(.didFail(
                method: method,
                url: url,
                error: error,
                duration: clock.now - start
            ))
            throw error
        }
    }
}

extension NetworkEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .willSend(method, url, attempt):
            attempt == 0
                ? "⇢ \(method.rawValue) \(url)"
                : "⇢ \(method.rawValue) \(url) — tentative \(attempt + 1)"
        case let .didReceive(method, url, statusCode, duration):
            "⇠ \(statusCode) \(method.rawValue) \(url) — \(duration)"
        case let .didFail(method, url, error, duration):
            "✗ \(method.rawValue) \(url) — \(error) — \(duration)"
        }
    }
}
