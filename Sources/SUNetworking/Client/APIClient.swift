import Foundation
import Synchronization

/// Ce qui exécute un endpoint et rend sa réponse décodée.
///
/// Le store ne connaît que ce protocole. Il ignore donc s'il parle à une vraie pile HTTP
/// ou à un double de test.
public protocol APIClient: Sendable {

    /// Exécute l'endpoint et décode sa réponse.
    func send<E: Endpoint>(_ endpoint: E) async throws(NetworkError) -> E.Response

    /// Annule les requêtes en cours d'un service.
    func cancel(service: APIService)

    /// Annule toutes les requêtes en cours.
    func cancelAll()
}

/// Le client standard : il compose l'URL, traverse la chaîne de middlewares, exécute le
/// transport, valide le statut et décode.
///
/// Il ne connaît ni `URLSession` ni le format des réponses — le transport et l'endpoint
/// s'en chargent. Ce qu'il apporte en propre, c'est l'assemblage, la validation du statut,
/// et le regroupement des requêtes identiques déjà en vol.
public final class PipelineClient: APIClient {

    private let transport: any Transport
    private let middlewares: [any Middleware]
    private let environment: APIEnvironment
    private let defaultPolicy: RequestPolicy

    /// Les requêtes en vol, pour que deux appels identiques n'en fassent qu'un.
    ///
    /// `Mutex` plutôt qu'un acteur : l'état est minuscule et les accès sont brefs, un
    /// saut d'isolation pour lire un dictionnaire serait disproportionné.
    private let inFlight = Mutex<[String: InFlightRequest]>([:])

    private struct InFlightRequest: Sendable {
        let id: UUID
        let service: APIService
        let task: Task<TransportResponse, any Error>
    }

    public init(
        transport: any Transport,
        environment: APIEnvironment,
        middlewares: [any Middleware] = [],
        defaultPolicy: RequestPolicy = .default
    ) {
        self.transport = transport
        self.environment = environment
        self.middlewares = middlewares
        self.defaultPolicy = defaultPolicy
    }

    // MARK: - Envoi

    public func send<E: Endpoint>(_ endpoint: E) async throws(NetworkError) -> E.Response {
        let policy = endpoint.policy ?? defaultPolicy
        let request = try buildRequest(for: endpoint, policy: policy)
        let context = RequestContext(
            request: request,
            service: endpoint.service,
            authentication: endpoint.authentication,
            policy: policy
        )

        let response = try await execute(context)

        guard response.isSuccess else {
            throw response.statusCode == 401
                ? .unauthorized(context: errorContext(request, response))
                : .httpFailed(context: errorContext(request, response))
        }

        do {
            return try endpoint.decode(response.data)
        } catch {
            throw .decodingFailed(
                context: errorContext(request, response),
                reason: "\(error)"
            )
        }
    }

    // MARK: - Annulation

    public func cancel(service: APIService) {
        let cancelled = inFlight.withLock { table -> [InFlightRequest] in
            let matching = table.filter { $0.value.service == service }
            matching.keys.forEach { table.removeValue(forKey: $0) }
            return Array(matching.values)
        }
        cancelled.forEach { $0.task.cancel() }
    }

    public func cancelAll() {
        let cancelled = inFlight.withLock { table -> [InFlightRequest] in
            let all = Array(table.values)
            table.removeAll()
            return all
        }
        cancelled.forEach { $0.task.cancel() }
    }

    // MARK: - Chaîne

    private func execute(_ context: RequestContext) async throws(NetworkError) -> TransportResponse {
        // Seules les requêtes idempotentes sont regroupées. Deux `POST` identiques
        // peuvent être deux intentions distinctes — deux commandes, deux messages — et
        // les fondre en une seule serait une perte de données silencieuse.
        guard context.request.method.isIdempotent else {
            return try await chain(context)
        }

        let key = deduplicationKey(for: context.request)
        let id = UUID()

        let (task, isOwner) = inFlight.withLock { table -> (Task<TransportResponse, any Error>, Bool) in
            if let existing = table[key], !existing.task.isCancelled {
                return (existing.task, false)
            }
            let task = Task<TransportResponse, any Error> { [self] in try await chain(context) }
            table[key] = InFlightRequest(id: id, service: context.service, task: task)
            return (task, true)
        }

        defer {
            if isOwner {
                inFlight.withLock { table in
                    if table[key]?.id == id { table.removeValue(forKey: key) }
                }
            }
        }

        do {
            return try await task.value
        } catch let error as NetworkError {
            throw error
        } catch {
            throw .cancelled
        }
    }

    /// Assemble les middlewares autour du transport. Le premier de la liste est le plus
    /// extérieur : il voit la requête en premier, et la réponse en dernier.
    private func chain(_ context: RequestContext) async throws(NetworkError) -> TransportResponse {
        try await Link(middlewares: middlewares, transport: transport, index: 0).run(context)
    }

    /// Un maillon de la chaîne : le middleware à l'index courant, et de quoi fabriquer le
    /// suivant.
    ///
    /// L'écriture naturelle serait un `reduce` qui compose des closures. Elle fait planter
    /// le compilateur Swift 6.3.3 en abaissement SIL — une closure à typed throws qui en
    /// retourne une autre. Ce maillon explicite produit le même comportement avec un seul
    /// niveau de closure.
    private struct Link: Sendable {
        let middlewares: [any Middleware]
        let transport: any Transport
        let index: Int

        func run(_ context: RequestContext) async throws(NetworkError) -> TransportResponse {
            guard index < middlewares.count else {
                return try await transport.execute(context.request)
            }
            let following = Link(middlewares: middlewares, transport: transport, index: index + 1)
            let next: MiddlewareChain = { context throws(NetworkError) in
                try await following.run(context)
            }
            return try await middlewares[index].intercept(context, next: next)
        }
    }

    // MARK: - Construction

    private func buildRequest<E: Endpoint>(
        for endpoint: E,
        policy: RequestPolicy
    ) throws(NetworkError) -> TransportRequest {
        guard let baseURL = environment.baseURL(for: endpoint.service) else {
            throw .invalidURL(service: endpoint.service.rawValue, path: endpoint.path)
        }

        let resolved = endpoint.path.isEmpty
            ? baseURL
            : baseURL.appending(path: endpoint.path)

        guard var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true) else {
            throw .invalidURL(service: endpoint.service.rawValue, path: endpoint.path)
        }
        if !endpoint.query.isEmpty {
            components.queryItems = endpoint.query
        }
        guard let url = components.url else {
            throw .invalidURL(service: endpoint.service.rawValue, path: endpoint.path)
        }

        var headers = endpoint.headers
        if let body = endpoint.body, headers["Content-Type"] == nil {
            headers["Content-Type"] = body.contentType
        }

        return TransportRequest(
            url: url,
            method: endpoint.method,
            headers: headers,
            body: endpoint.body,
            timeout: policy.timeout
        )
    }

    private func deduplicationKey(for request: TransportRequest) -> String {
        var key = "\(request.method.rawValue) \(request.url.absoluteString)"
        if let body = request.body {
            key += " #\(body.data.hashValue)"
        }
        return key
    }

    private func errorContext(
        _ request: TransportRequest,
        _ response: TransportResponse
    ) -> NetworkErrorContext {
        NetworkErrorContext(
            method: request.method.rawValue,
            url: request.url.absoluteString,
            requestHeaders: request.headers,
            statusCode: response.statusCode,
            responseBody: String(data: response.data, encoding: .utf8)
        )
    }
}
