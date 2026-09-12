import Foundation
import SULogger

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
/// ``DefaultNetworkLogger`` couvre le cas courant en écrivant dans `SULogger`. Ce protocole
/// reste le point d'extension pour une app qui veut router ailleurs — Crashlytics, Sentry,
/// un journal maison.
public protocol NetworkLogger: Sendable {
    func log(_ event: NetworkEvent)
}

/// Le journal par défaut : écrit dans ``SULogger/Log``, catégorie `network`.
///
/// Il existe pour que `LoggingMiddleware()` fonctionne sans rien câbler. Une app qui veut
/// autre chose — Crashlytics, Sentry — implémente ``NetworkLogger`` et le passe en
/// paramètre.
public struct DefaultNetworkLogger: NetworkLogger {

    public init() {}

    public func log(_ event: NetworkEvent) {
        switch event {
        case .willSend:
            Log.debug("\(event)", category: .network)

        case let .didReceive(_, _, statusCode, _):
            // Un 4xx/5xx n'est pas une panne du client, mais c'est ce qu'on cherche en
            // premier dans un journal : il mérite de sortir du bruit des `debug`.
            if (200..<400).contains(statusCode) {
                Log.debug("\(event)", category: .network)
            } else {
                Log.warning("\(event)", category: .network)
            }

        case .didFail:
            Log.error("\(event)", category: .network)
        }
    }
}

/// Raconte chaque requête au `NetworkLogger` fourni, et mesure sa durée.
public struct LoggingMiddleware: Middleware {

    private let logger: any NetworkLogger

    /// - Parameter logger: par défaut ``DefaultNetworkLogger``, qui écrit dans `SULogger`.
    public init(logger: any NetworkLogger = DefaultNetworkLogger()) {
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
