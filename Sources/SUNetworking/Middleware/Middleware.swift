import Foundation

/// Ce qui circule dans la chaîne de middlewares : la requête en construction, et ce qu'il
/// faut savoir pour décider quoi en faire.
public struct RequestContext: Sendable {

    /// La requête, que chaque middleware peut amender avant de passer la main.
    public var request: TransportRequest

    public let service: APIService
    public let authentication: AuthRequirement
    public let policy: RequestPolicy

    /// La tentative en cours, à partir de 0. Le middleware de retry l'incrémente.
    public var attempt: Int

    public init(
        request: TransportRequest,
        service: APIService,
        authentication: AuthRequirement,
        policy: RequestPolicy,
        attempt: Int = 0
    ) {
        self.request = request
        self.service = service
        self.authentication = authentication
        self.policy = policy
        self.attempt = attempt
    }

    /// Le contexte d'erreur correspondant à cette requête.
    var errorContext: NetworkErrorContext {
        NetworkErrorContext(
            method: request.method.rawValue,
            url: request.url.absoluteString,
            requestHeaders: request.headers
        )
    }
}

/// La suite de la chaîne, vue depuis un middleware.
public typealias MiddlewareChain = @Sendable (RequestContext) async throws(NetworkError) -> TransportResponse

/// Un maillon entre le client et le transport.
///
/// Chaque middleware reçoit le contexte, l'amende s'il le souhaite, et appelle `next`
/// pour continuer vers le transport. Il peut aussi court-circuiter — ne pas appeler
/// `next` — ou rejouer en appelant `next` plusieurs fois, ce qui est exactement ce que
/// fait ``RetryMiddleware``.
///
/// L'ordre compte : le premier de la liste est le plus extérieur, donc le premier à voir
/// la requête et le dernier à voir la réponse.
public protocol Middleware: Sendable {
    func intercept(
        _ context: RequestContext,
        next: @escaping MiddlewareChain
    ) async throws(NetworkError) -> TransportResponse
}
