import Foundation

/// Une requête HTTP réduite à ce qu'un transport a besoin de savoir : où, comment, avec
/// quels octets, et pendant combien de temps.
public struct TransportRequest: Sendable, Equatable {
    public var url: URL
    public var method: HTTPMethod
    public var headers: [String: String]
    public var body: RequestBody?
    public var timeout: Duration

    public init(
        url: URL,
        method: HTTPMethod,
        headers: [String: String] = [:],
        body: RequestBody? = nil,
        timeout: Duration = .seconds(30)
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

/// Ce qu'un transport rend : des octets, un statut, des en-têtes. Rien de décodé.
public struct TransportResponse: Sendable, Equatable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }

    /// Un en-tête, sans se soucier de la casse — HTTP ne la garantit pas.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Vrai pour un statut 2xx.
    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// Ce qui exécute réellement un aller-retour HTTP.
///
/// C'est le seul endroit du module qui connaît `URLSession`. Le reste — middlewares,
/// client, store — ne voit que ce protocole, ce qui rend le double de test aussi
/// légitime que la vraie implémentation.
public protocol Transport: Sendable {
    func execute(_ request: TransportRequest) async throws(NetworkError) -> TransportResponse
}
