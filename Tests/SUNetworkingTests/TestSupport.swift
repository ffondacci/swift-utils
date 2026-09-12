import Foundation
import Synchronization
import Testing
@testable import SUNetworking

// MARK: - Environnement

extension APIService {
    static let test: APIService = "test"
    static let other: APIService = "other"
}

let testEnvironment = APIEnvironment([
    .test: URL(string: "https://api.example.com/v1")!,
    .other: URL(string: "https://other.example.com")!,
])

// MARK: - Valeurs

struct Greeting: Codable, Sendable, Equatable {
    var message: String
}

// MARK: - Endpoints

/// Le cas minimal : un GET public décodé en JSON.
struct GetGreeting: Endpoint {
    typealias Response = Greeting
    var service: APIService { .test }
    var path: String { "/greeting" }
}

/// De quoi vérifier la composition de l'URL et des en-têtes.
struct SearchGreetings: Endpoint {
    typealias Response = Greeting
    let term: String
    var service: APIService { .test }
    var path: String { "/greetings/search" }
    var query: [URLQueryItem] { [URLQueryItem(name: "q", value: term)] }
    var headers: [String: String] { ["X-Custom": "endpoint"] }
}

/// Un POST : non idempotent, donc ni rejoué ni regroupé.
struct PostGreeting: Endpoint {
    typealias Response = Greeting
    let greeting: Greeting
    var service: APIService { .test }
    var path: String { "/greeting" }
    var method: HTTPMethod { .post }
    var body: RequestBody? { try? .json(greeting) }
}

/// Exige un jeton.
struct GetPrivate: Endpoint {
    typealias Response = Greeting
    var service: APIService { .test }
    var path: String { "/private" }
    var authentication: AuthRequirement { .required }
}

/// Accepte un jeton sans l'exiger.
struct GetOptional: Endpoint {
    typealias Response = Greeting
    var service: APIService { .test }
    var path: String { "/optional" }
    var authentication: AuthRequirement { .optional }
}

/// Pointe un service absent de l'environnement.
struct GetUnknownService: Endpoint {
    typealias Response = Greeting
    var service: APIService { "jamais-declare" }
    var path: String { "/nope" }
}

/// Politique de reprise rapide, pour que les tests ne dorment pas.
struct GetWithFastRetry: Endpoint {
    typealias Response = Greeting
    var service: APIService { .test }
    var path: String { "/flaky" }
    var policy: RequestPolicy? {
        RequestPolicy(
            timeout: .seconds(1),
            retry: RetryPolicy(maxRetries: 2, backoff: .constant(.milliseconds(1)))
        )
    }
}

// MARK: - Doubles

/// Sert des jetons programmés et note comment on les lui a demandés.
actor StubTokenProvider: TokenProvider {
    private var tokens: [String?]
    private(set) var refreshRequests: [Bool] = []

    init(_ tokens: [String?]) {
        self.tokens = tokens.isEmpty ? [nil] : tokens
    }

    func token(forceRefresh: Bool) async throws -> String? {
        refreshRequests.append(forceRefresh)
        return tokens.count > 1 ? tokens.removeFirst() : tokens[0]
    }

    var callCount: Int { refreshRequests.count }
}

/// Un fournisseur de jeton qui échoue — session expirée, réseau coupé au refresh.
struct FailingTokenProvider: TokenProvider {
    struct Failure: Error {}
    func token(forceRefresh: Bool) async throws -> String? { throw Failure() }
}

/// Note les événements réseau. `Mutex` plutôt qu'un acteur : les vues de test lisent
/// l'état de façon synchrone.
final class SpyLogger: NetworkLogger {
    private let storage = Mutex<[NetworkEvent]>([])

    func log(_ event: NetworkEvent) {
        storage.withLock { $0.append(event) }
    }

    var events: [NetworkEvent] { storage.withLock { $0 } }
}

/// Un carnet partagé entre middlewares.
///
/// `Mutex` est non-copiable : il ne peut vivre que dans un type référence. C'est aussi ce
/// qui permet de le partager entre plusieurs middlewares sans le dupliquer.
final class Trace: Sendable {
    private let entries = Mutex<[String]>([])

    func record(_ entry: String) { entries.withLock { $0.append(entry) } }
    var recorded: [String] { entries.withLock { $0 } }
}

/// Un middleware qui note son passage, pour vérifier l'ordre de la chaîne.
struct TracingMiddleware: Middleware {
    let name: String
    let trace: Trace

    func intercept(
        _ context: RequestContext,
        next: @escaping MiddlewareChain
    ) async throws(NetworkError) -> TransportResponse {
        trace.record("→\(name)")
        let response = try await next(context)
        trace.record("←\(name)")
        return response
    }
}

/// Un client qui échoue à tous les coups, pour tester ce que le store fait d'une erreur.
struct FailingClient: APIClient {
    let error: NetworkError

    func send<E: Endpoint>(_ endpoint: E) async throws(NetworkError) -> E.Response {
        throw error
    }

    func cancel(service: APIService) {}
    func cancelAll() {}
}

// MARK: - Raccourcis

func greetingJSON(_ message: String = "bonjour") -> String {
    #"{"message":"\#(message)"}"#
}

func makeClient(
    _ outcomes: [MockTransport.Outcome] = [.status(200, json: greetingJSON())],
    middlewares: [any Middleware] = [],
    policy: RequestPolicy = RequestPolicy(retry: .none)
) -> (client: PipelineClient, transport: MockTransport) {
    let transport = MockTransport(outcomes)
    let client = PipelineClient(
        transport: transport,
        environment: testEnvironment,
        middlewares: middlewares,
        defaultPolicy: policy
    )
    return (client, transport)
}
