import Foundation
import Testing
@testable import SUNetworking

/// Ce que le client apporte en propre : composer l'URL, valider le statut, décoder, et
/// traduire les échecs en erreurs diagnosticables.
@Suite("Client")
struct PipelineClientTests {

    @Test("une réponse 2xx est décodée vers le type de l'endpoint")
    func decodesSuccessfulResponse() async throws {
        let (client, _) = makeClient([.status(200, json: greetingJSON("salut"))])

        let greeting = try await client.send(GetGreeting())

        #expect(greeting == Greeting(message: "salut"))
    }

    @Test("l'URL compose la base du service, le chemin et la query")
    func buildsURL() async throws {
        let (client, transport) = makeClient()

        _ = try await client.send(SearchGreetings(term: "bon jour"))

        let request = await transport.lastRequest
        #expect(request?.url.absoluteString == "https://api.example.com/v1/greetings/search?q=bon%20jour")
    }

    @Test("les en-têtes de l'endpoint sont transmis, et le Content-Type déduit du corps")
    func forwardsHeaders() async throws {
        let (client, transport) = makeClient()

        _ = try await client.send(SearchGreetings(term: "x"))
        let searchHeaders = await transport.lastRequest?.headers
        #expect(searchHeaders?["X-Custom"] == "endpoint")

        _ = try await client.send(PostGreeting(greeting: Greeting(message: "hop")))
        let postHeaders = await transport.lastRequest?.headers
        #expect(postHeaders?["Content-Type"] == "application/json")
    }

    @Test("un service absent de l'environnement échoue avant tout appel réseau")
    func unknownServiceFailsEarly() async throws {
        let (client, transport) = makeClient()

        let error = await #expect(throws: NetworkError.self) {
            try await client.send(GetUnknownService())
        }

        #expect(error == .invalidURL(service: "jamais-declare", path: "/nope"))
        let count = await transport.requestCount
        #expect(count == 0)
    }

    @Test("un statut hors 2xx devient une erreur qui porte le statut et le corps")
    func httpErrorCarriesContext() async throws {
        let (client, _) = makeClient([.status(503, json: #"{"error":"maintenance"}"#)])

        let error = await #expect(throws: NetworkError.self) {
            try await client.send(GetGreeting())
        }

        #expect(error?.statusCode == 503)
        #expect(error?.context?.responseBody?.contains("maintenance") == true)
        #expect(error?.context?.method == "GET")
    }

    @Test("un 401 est distingué des autres erreurs HTTP")
    func unauthorizedIsItsOwnCase() async throws {
        let (client, _) = makeClient([.status(401)])

        let error = await #expect(throws: NetworkError.self) {
            try await client.send(GetGreeting())
        }

        guard case .unauthorized = error else {
            Issue.record("attendu .unauthorized, reçu \(String(describing: error))")
            return
        }
    }

    @Test("une réponse illisible remonte une erreur de décodage, pas un succès vide")
    func decodingFailureIsReported() async throws {
        let (client, _) = makeClient([.status(200, json: #"{"wrong":"shape"}"#)])

        let error = await #expect(throws: NetworkError.self) {
            try await client.send(GetGreeting())
        }

        guard case let .decodingFailed(context, _) = error else {
            Issue.record("attendu .decodingFailed, reçu \(String(describing: error))")
            return
        }
        #expect(context.statusCode == 200)
    }

    @Test("deux GET identiques simultanés ne font qu'une requête")
    func deduplicatesIdenticalGETs() async throws {
        let (client, transport) = makeClient()

        async let first = client.send(GetGreeting())
        async let second = client.send(GetGreeting())
        _ = try await [first, second]

        let count = await transport.requestCount
        #expect(count == 1)
    }

    @Test("deux POST identiques simultanés partent bien en deux requêtes")
    func doesNotDeduplicatePOSTs() async throws {
        let (client, transport) = makeClient()
        let endpoint = PostGreeting(greeting: Greeting(message: "hop"))

        async let first = client.send(endpoint)
        async let second = client.send(endpoint)
        _ = try await [first, second]

        let count = await transport.requestCount
        #expect(count == 2)
    }

    @Test("deux GET sur des chemins différents ne sont pas regroupés")
    func differentPathsAreNotDeduplicated() async throws {
        let (client, transport) = makeClient()

        async let first = client.send(GetGreeting())
        async let second = client.send(SearchGreetings(term: "x"))
        _ = try await [first, second]

        let count = await transport.requestCount
        #expect(count == 2)
    }
}
