import Foundation
import Testing
@testable import SUNetworking

/// Une erreur finit dans un log, et un log finit souvent ailleurs.
@Suite("Erreurs")
struct NetworkErrorTests {

    @Test("un en-tête Bearer n'apparaît jamais en clair dans le contexte")
    func bearerTokenIsMasked() {
        let context = NetworkErrorContext(
            method: "GET",
            url: "https://api.example.com/v1/private",
            requestHeaders: ["Authorization": "Bearer eyJhbGciOiJIUzI1NiJ9.secret"]
        )

        let value = context.requestHeaders["Authorization"]
        #expect(value?.contains("secret") == false)
        #expect(value?.contains("masqués") == true)
    }

    @Test("un en-tête anodin reste lisible")
    func harmlessHeaderIsKept() {
        let context = NetworkErrorContext(
            method: "GET",
            url: "https://api.example.com",
            requestHeaders: ["Accept": "application/json"]
        )

        #expect(context.requestHeaders["Accept"] == "application/json")
    }

    @Test("une valeur anormalement longue est masquée par précaution")
    func longValueIsMasked() {
        let context = NetworkErrorContext(
            method: "GET",
            url: "https://api.example.com",
            requestHeaders: ["X-Session": String(repeating: "a", count: 100)]
        )

        #expect(context.requestHeaders["X-Session"]?.contains("masqués") == true)
    }

    @Test("un corps de réponse énorme est tronqué")
    func longBodyIsTruncated() {
        let context = NetworkErrorContext(
            method: "GET",
            url: "https://api.example.com",
            responseBody: String(repeating: "x", count: 10_000)
        )

        #expect(context.responseBody?.count == 2_000)
    }

    @Test(
        "seules les pannes transitoires sont déclarées rejouables",
        arguments: [
            (NetworkError.transportFailed(context: .init(method: "GET", url: "u"), reason: "r"), true),
            (NetworkError.httpFailed(context: .init(method: "GET", url: "u", statusCode: 503)), true),
            (NetworkError.httpFailed(context: .init(method: "GET", url: "u", statusCode: 429)), true),
            (NetworkError.httpFailed(context: .init(method: "GET", url: "u", statusCode: 404)), false),
            (NetworkError.decodingFailed(context: .init(method: "GET", url: "u"), reason: "r"), false),
            (NetworkError.invalidURL(service: "s", path: "p"), false),
            (NetworkError.tokenUnavailable(reason: "r"), false),
            (NetworkError.cancelled, false),
        ]
    )
    func retryability(error: NetworkError, expected: Bool) {
        #expect(error.isRetryable == expected)
    }

    @Test("la description porte le verbe, l'URL et le statut")
    func descriptionIsDiagnosable() {
        let error = NetworkError.httpFailed(
            context: .init(method: "POST", url: "https://api.example.com/v1/orders", statusCode: 422)
        )

        let text = error.description
        #expect(text.contains("POST"))
        #expect(text.contains("/v1/orders"))
        #expect(text.contains("422"))
    }
}
