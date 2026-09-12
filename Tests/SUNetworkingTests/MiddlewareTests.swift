import Foundation
import Synchronization
import Testing
@testable import SUNetworking

@Suite("Middlewares")
struct MiddlewareTests {

    // MARK: - Chaîne

    @Test("la chaîne est traversée dans l'ordre à l'aller, en sens inverse au retour")
    func chainOrder() async throws {
        let trace = Trace()
        let (client, _) = makeClient(middlewares: [
            TracingMiddleware(name: "A", trace: trace),
            TracingMiddleware(name: "B", trace: trace),
        ])

        _ = try await client.send(GetGreeting())

        #expect(trace.recorded == ["→A", "→B", "←B", "←A"])
    }

    // MARK: - En-têtes par défaut

    @Test("les en-têtes par défaut sont ajoutés")
    func defaultHeadersAreAdded() async throws {
        let (client, transport) = makeClient(middlewares: [
            DefaultHeadersMiddleware(["Accept": "application/json", "X-App": "lensy"])
        ])

        _ = try await client.send(GetGreeting())

        let headers = await transport.lastRequest?.headers
        #expect(headers?["Accept"] == "application/json")
        #expect(headers?["X-App"] == "lensy")
    }

    @Test("un en-tête posé par l'endpoint n'est pas écrasé par le défaut")
    func endpointHeaderWins() async throws {
        let (client, transport) = makeClient(middlewares: [
            DefaultHeadersMiddleware(["X-Custom": "default"])
        ])

        _ = try await client.send(SearchGreetings(term: "x"))

        let headers = await transport.lastRequest?.headers
        #expect(headers?["X-Custom"] == "endpoint")
    }

    // MARK: - Jeton

    @Test("un endpoint public ne demande aucun jeton")
    func publicEndpointSkipsToken() async throws {
        let provider = StubTokenProvider(["jeton"])
        let (client, transport) = makeClient(middlewares: [TokenMiddleware(provider: provider)])

        _ = try await client.send(GetGreeting())

        let calls = await provider.callCount
        let headers = await transport.lastRequest?.headers
        #expect(calls == 0)
        #expect(headers?["Authorization"] == nil)
    }

    @Test("un endpoint authentifié part avec le jeton en Bearer")
    func authenticatedEndpointCarriesToken() async throws {
        let provider = StubTokenProvider(["abc123"])
        let (client, transport) = makeClient(middlewares: [TokenMiddleware(provider: provider)])

        _ = try await client.send(GetPrivate())

        let headers = await transport.lastRequest?.headers
        #expect(headers?["Authorization"] == "Bearer abc123")
    }

    @Test("un en-tête et un schéma personnalisés fonctionnent — cas App Check")
    func customHeaderAndScheme() async throws {
        let provider = StubTokenProvider(["appcheck-token"])
        let (client, transport) = makeClient(middlewares: [
            TokenMiddleware(provider: provider, header: "X-Firebase-AppCheck", scheme: nil)
        ])

        _ = try await client.send(GetPrivate())

        let headers = await transport.lastRequest?.headers
        #expect(headers?["X-Firebase-AppCheck"] == "appcheck-token")
    }

    @Test("sans jeton, un endpoint qui l'exige échoue sans partir sur le réseau")
    func requiredWithoutTokenFailsEarly() async throws {
        let provider = StubTokenProvider([nil])
        let (client, transport) = makeClient(middlewares: [TokenMiddleware(provider: provider)])

        let error = await #expect(throws: NetworkError.self) {
            try await client.send(GetPrivate())
        }

        guard case .tokenUnavailable = error else {
            Issue.record("attendu .tokenUnavailable, reçu \(String(describing: error))")
            return
        }
        let count = await transport.requestCount
        #expect(count == 0)
    }

    @Test("sans jeton, un endpoint qui le tolère part quand même")
    func optionalWithoutTokenProceeds() async throws {
        let provider = StubTokenProvider([nil])
        let (client, transport) = makeClient(middlewares: [TokenMiddleware(provider: provider)])

        _ = try await client.send(GetOptional())

        let count = await transport.requestCount
        let headers = await transport.lastRequest?.headers
        #expect(count == 1)
        #expect(headers?["Authorization"] == nil)
    }

    @Test("un fournisseur en échec fait échouer l'endpoint qui exige un jeton")
    func failingProviderFailsRequiredEndpoint() async throws {
        let (client, _) = makeClient(middlewares: [
            TokenMiddleware(provider: FailingTokenProvider())
        ])

        let error = await #expect(throws: NetworkError.self) {
            try await client.send(GetPrivate())
        }

        guard case .tokenUnavailable = error else {
            Issue.record("attendu .tokenUnavailable, reçu \(String(describing: error))")
            return
        }
    }

    @Test("un 401 déclenche un rafraîchissement et un seul nouvel essai")
    func refreshesOnceOnUnauthorized() async throws {
        let provider = StubTokenProvider(["périmé", "frais"])
        let (client, transport) = makeClient(
            [.status(401), .status(200, json: greetingJSON("ok"))],
            middlewares: [TokenMiddleware(provider: provider)]
        )

        let greeting = try await client.send(GetPrivate())

        let refreshes = await provider.refreshRequests
        let headers = await transport.lastRequest?.headers
        #expect(greeting == Greeting(message: "ok"))
        #expect(refreshes == [false, true])
        #expect(headers?["Authorization"] == "Bearer frais")
    }

    @Test("un 401 qui persiste après rafraîchissement remonte une erreur")
    func persistentUnauthorizedFails() async throws {
        let provider = StubTokenProvider(["a", "b"])
        let (client, _) = makeClient(
            [.status(401), .status(401)],
            middlewares: [TokenMiddleware(provider: provider)]
        )

        let error = await #expect(throws: NetworkError.self) {
            try await client.send(GetPrivate())
        }

        guard case .unauthorized = error else {
            Issue.record("attendu .unauthorized, reçu \(String(describing: error))")
            return
        }
    }

    // MARK: - Reprise

    @Test("un 503 est rejoué jusqu'au succès")
    func retriesUntilSuccess() async throws {
        let (client, transport) = makeClient(
            [.status(503), .status(503), .status(200, json: greetingJSON("enfin"))],
            middlewares: [RetryMiddleware()]
        )

        let greeting = try await client.send(GetWithFastRetry())

        let count = await transport.requestCount
        #expect(greeting == Greeting(message: "enfin"))
        #expect(count == 3)
    }

    @Test("les tentatives s'arrêtent au plafond de la politique")
    func stopsAtMaxRetries() async throws {
        let (client, transport) = makeClient(
            [.status(503)],
            middlewares: [RetryMiddleware()]
        )

        let error = await #expect(throws: NetworkError.self) {
            try await client.send(GetWithFastRetry())
        }

        let count = await transport.requestCount
        #expect(error?.statusCode == 503)
        #expect(count == 3, "un essai initial plus deux reprises")
    }

    @Test("un 404 n'est jamais rejoué")
    func doesNotRetryClientErrors() async throws {
        let (client, transport) = makeClient(
            [.status(404)],
            middlewares: [RetryMiddleware()]
        )

        _ = await #expect(throws: NetworkError.self) {
            try await client.send(GetWithFastRetry())
        }

        let count = await transport.requestCount
        #expect(count == 1)
    }

    @Test("un POST n'est pas rejoué par défaut")
    func doesNotRetryNonIdempotentMethods() async throws {
        let (client, transport) = makeClient(
            [.status(503)],
            middlewares: [RetryMiddleware()],
            policy: RequestPolicy(retry: RetryPolicy(maxRetries: 2, backoff: .constant(.milliseconds(1))))
        )

        _ = await #expect(throws: NetworkError.self) {
            try await client.send(PostGreeting(greeting: Greeting(message: "hop")))
        }

        let count = await transport.requestCount
        #expect(count == 1)
    }

    @Test("une panne de transport est rejouée")
    func retriesTransportFailures() async throws {
        let context = NetworkErrorContext(method: "GET", url: "https://api.example.com/v1/flaky")
        let (client, transport) = makeClient(
            [
                .failure(.transportFailed(context: context, reason: "réseau indisponible")),
                .status(200, json: greetingJSON("revenu")),
            ],
            middlewares: [RetryMiddleware()]
        )

        let greeting = try await client.send(GetWithFastRetry())

        let count = await transport.requestCount
        #expect(greeting == Greeting(message: "revenu"))
        #expect(count == 2)
    }

    // MARK: - Journal

    @Test("le journal reçoit le départ et l'arrivée de chaque requête")
    func logsRequestLifecycle() async throws {
        let logger = SpyLogger()
        let (client, _) = makeClient(middlewares: [LoggingMiddleware(logger: logger)])

        _ = try await client.send(GetGreeting())

        #expect(logger.events.count == 2)
        guard case .willSend = logger.events.first, case .didReceive = logger.events.last else {
            Issue.record("événements inattendus : \(logger.events)")
            return
        }
    }

    @Test("le journal reçoit l'échec")
    func logsFailure() async throws {
        let logger = SpyLogger()
        let (client, _) = makeClient([.status(500)], middlewares: [LoggingMiddleware(logger: logger)])

        _ = await #expect(throws: NetworkError.self) {
            try await client.send(GetGreeting())
        }

        // Le 500 remonte comme une réponse, pas comme une panne de transport : c'est le
        // client qui le transforme en erreur, au-dessus du middleware.
        guard case let .didReceive(_, _, statusCode, _) = logger.events.last else {
            Issue.record("événements inattendus : \(logger.events)")
            return
        }
        #expect(statusCode == 500)
    }
}
