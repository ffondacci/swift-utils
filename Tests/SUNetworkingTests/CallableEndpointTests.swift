import Foundation
import Testing
@testable import SUNetworking

/// Les Cloud Functions `onCall` : l'enveloppe du format, les défauts, et le fait que
/// chaque défaut se surcharge sans faire perdre les autres.
@Suite("Fonctions appelables")
struct CallableEndpointTests {

    private func body(of request: TransportRequest?) -> [String: Any]? {
        guard let data = request?.body?.data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Enveloppe

    @Test("la charge utile est emballée dans data")
    func payloadIsWrapped() async throws {
        let (client, transport) = makeClient([.status(200, json: callableJSON())])

        _ = try await client.send(SendFeedback(payload: Feedback(message: "super", rating: 5)))

        let request = await transport.lastRequest
        let payload = body(of: request)?["data"] as? [String: Any]
        #expect(payload?["message"] as? String == "super")
        #expect(payload?["rating"] as? Int == 5)
    }

    @Test("la réponse est déballée de result")
    func resultIsUnwrapped() async throws {
        let (client, _) = makeClient([.status(200, json: #"{"result":{"id":"abc"}}"#)])

        let confirmation = try await client.send(
            SendFeedback(payload: Feedback(message: "x", rating: 1))
        )

        #expect(confirmation == Confirmation(id: "abc"))
    }

    @Test("une réponse sans enveloppe result est une erreur de décodage")
    func missingEnvelopeIsADecodingError() async throws {
        let (client, _) = makeClient([.status(200, json: #"{"id":"abc"}"#)])

        let error = await #expect(throws: NetworkError.self) {
            try await client.send(SendFeedback(payload: Feedback(message: "x", rating: 1)))
        }

        guard case .decodingFailed = error else {
            Issue.record("attendu .decodingFailed, reçu \(String(describing: error))")
            return
        }
    }

    // MARK: - Défauts

    @Test("par défaut : POST, chemin égal au nom, sur le service cloudFunctions")
    func defaults() async throws {
        let (client, transport) = makeClient([.status(200, json: callableJSON())])

        _ = try await client.send(SendFeedback(payload: Feedback(message: "x", rating: 1)))

        let request = await transport.lastRequest
        #expect(request?.method == .post)
        #expect(request?.url.absoluteString == "https://europe-west1-lensy.cloudfunctions.net/sendFeedback")
    }

    @Test("par défaut, une fonction appelable exige un jeton")
    func defaultsToAuthenticated() async throws {
        let provider = StubTokenProvider(["jeton"])
        let (client, transport) = makeClient(
            [.status(200, json: callableJSON())],
            middlewares: [TokenMiddleware(provider: provider)]
        )

        _ = try await client.send(SendFeedback(payload: Feedback(message: "x", rating: 1)))

        let headers = await transport.lastRequest?.headers
        #expect(headers?["Authorization"] == "Bearer jeton")
    }

    // MARK: - Forme réglable au point d'appel

    @Test("la forme courte marche sans déclarer de type")
    func inlineFormWorks() async throws {
        let (client, transport) = makeClient([.status(200, json: #"{"result":{"id":"xyz"}}"#)])

        let confirmation: Confirmation = try await client.send(
            Callable("sendFeedback", payload: Feedback(message: "hop", rating: 3))
        )

        let request = await transport.lastRequest
        #expect(confirmation == Confirmation(id: "xyz"))
        #expect(request?.method == .post)
        #expect(request?.url.path() == "/sendFeedback")
    }

    @Test("une fonction sans argument n'exige pas de charge utile")
    func noPayloadForm() async throws {
        let (client, transport) = makeClient([.status(200, json: #"{"result":{"id":"stats"}}"#)])

        let confirmation: Confirmation = try await client.send(Callable("dailyStats"))

        let request = await transport.lastRequest
        #expect(confirmation == Confirmation(id: "stats"))
        #expect(request?.url.path() == "/dailyStats")
    }

    @Test("surcharger un réglage ne fait pas perdre les autres")
    func overridingOneSettingKeepsTheRest() async throws {
        let (client, transport) = makeClient([.status(200, json: callableJSON())])

        let _: Confirmation = try await client.send(
            Callable(
                "sendFeedback",
                payload: Feedback(message: "x", rating: 1),
                headers: ["X-Debug": "1"]
            )
        )

        let request = await transport.lastRequest
        #expect(request?.headers["X-Debug"] == "1")
        #expect(request?.method == .post, "le défaut POST est conservé")
        #expect(request?.url.path() == "/sendFeedback", "le chemin par défaut est conservé")
    }

    @Test("l'authentification se relâche au point d'appel")
    func authenticationIsOverridable() async throws {
        let provider = StubTokenProvider([nil])
        let (client, transport) = makeClient(
            [.status(200, json: callableJSON())],
            middlewares: [TokenMiddleware(provider: provider)]
        )

        // `.required` échouerait sans jeton ; `.optional` laisse passer.
        let _: Confirmation = try await client.send(
            Callable("publicStats", authentication: .optional)
        )

        let count = await transport.requestCount
        #expect(count == 1)
    }

    @Test("la politique de reprise se règle au point d'appel")
    func policyIsOverridable() async throws {
        let (client, transport) = makeClient(
            [.status(503), .status(200, json: #"{"result":{"id":"a"}}"#)],
            middlewares: [RetryMiddleware()]
        )

        let _: Confirmation = try await client.send(
            Callable(
                "flakyFunction",
                policy: RequestPolicy(
                    retry: RetryPolicy(
                        maxRetries: 1,
                        backoff: .constant(.milliseconds(1)),
                        idempotentMethodsOnly: false
                    )
                )
            )
        )

        let count = await transport.requestCount
        #expect(count == 2, "le POST est rejoué parce qu'on l'a explicitement autorisé")
    }

    @Test("le service se détourne vers un autre environnement")
    func serviceIsOverridable() async throws {
        let (client, transport) = makeClient([.status(200, json: callableJSON())])

        let _: Confirmation = try await client.send(
            Callable("sendFeedback", payload: Feedback(message: "x", rating: 1), service: .other)
        )

        let request = await transport.lastRequest
        #expect(request?.url.absoluteString == "https://other.example.com/sendFeedback")
    }
}
