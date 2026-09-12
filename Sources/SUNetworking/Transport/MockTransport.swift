import Foundation

/// Un transport qui ne touche jamais au réseau.
///
/// Il sert aux tests du module, et à ceux des apps qui le consomment : un test qui
/// dépend d'un vrai serveur teste le serveur, pas le code. Il enregistre tout ce qu'on
/// lui demande, ce qui permet d'affirmer *comment* la requête a été formée, pas seulement
/// ce qu'elle a rendu.
public actor MockTransport: Transport {

    /// Ce qu'une réponse programmée peut faire.
    public enum Outcome: Sendable {
        case success(TransportResponse)
        case failure(NetworkError)

        /// Raccourci : un statut et un corps JSON.
        public static func status(_ code: Int, json: String = "{}", headers: [String: String] = [:]) -> Outcome {
            .success(TransportResponse(data: Data(json.utf8), statusCode: code, headers: headers))
        }
    }

    /// Les réponses à servir, dans l'ordre. La dernière est répétée si les requêtes
    /// continuent — ce qui rend un test de retry lisible : on programme l'échec, puis le
    /// succès.
    private var outcomes: [Outcome]

    /// Tout ce qui est passé par ici, dans l'ordre.
    public private(set) var recordedRequests: [TransportRequest] = []

    public init(_ outcomes: [Outcome] = [.status(200)]) {
        self.outcomes = outcomes.isEmpty ? [.status(200)] : outcomes
    }

    public init(_ outcome: Outcome) {
        self.init([outcome])
    }

    /// Remplace la file de réponses.
    public func setOutcomes(_ outcomes: [Outcome]) {
        self.outcomes = outcomes.isEmpty ? [.status(200)] : outcomes
    }

    public func execute(_ request: TransportRequest) throws(NetworkError) -> TransportResponse {
        recordedRequests.append(request)

        let outcome = outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        switch outcome {
        case let .success(response): return response
        case let .failure(error): throw error
        }
    }

    /// Le nombre de requêtes reçues — la mesure d'un test de retry.
    public var requestCount: Int { recordedRequests.count }

    /// La dernière requête reçue.
    public var lastRequest: TransportRequest? { recordedRequests.last }
}
