import Foundation

/// Le service des Cloud Functions appelables.
///
/// C'est le seul identifiant que le module déclare, et ce n'est **qu'un nom** : l'URL
/// reste chez vous, dans votre ``APIEnvironment``.
///
/// ```swift
/// extension APIEnvironment {
///     static let production = APIEnvironment([
///         .cloudFunctions: URL(string: "https://europe-west1-lensy.cloudfunctions.net")!,
///     ])
/// }
/// ```
public extension APIService {
    static let cloudFunctions: APIService = "cloudFunctions"
}

/// Une Cloud Function appelable (`onCall`).
///
/// Le protocole ne fait qu'une chose de plus qu'un ``Endpoint`` : il connaît l'enveloppe
/// du format `onCall`, qui emballe la requête dans `{"data": …}` et rend la réponse dans
/// `{"result": …}`.
///
/// Pour une fonction HTTP (`onRequest`), un ``Endpoint`` ordinaire suffit.
///
/// ```swift
/// struct SendFeedback: CallableEndpoint {
///     typealias Response = Confirmation
///
///     let payload: FeedbackPayload
///     var functionName: String { "sendFeedback" }
/// }
/// ```
///
/// Tout le reste a un défaut — `POST`, authentification obligatoire, chemin égal au nom de
/// la fonction — et **tout est surchargeable** : redéfinissez `method`, `headers`,
/// `authentication`, `policy` ou `service` comme n'importe quel endpoint.
///
/// Pour ne pas déclarer un type par fonction, voir ``Callable``.
public protocol CallableEndpoint: Endpoint where Response: Decodable {

    /// Ce que la fonction reçoit. ``NoPayload`` pour une fonction sans argument.
    associatedtype Payload: Encodable & Sendable

    /// Le nom de la fonction déployée.
    var functionName: String { get }

    /// Les arguments.
    var payload: Payload { get }
}

public extension CallableEndpoint {
    var service: APIService { .cloudFunctions }
    var path: String { "/\(functionName)" }
    var method: HTTPMethod { .post }
    var authentication: AuthRequirement { .required }

    var body: RequestBody? {
        try? .json(CallableRequest(data: payload))
    }

    func decode(_ data: Data) throws -> Response {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CallableResponse<Response>.self, from: data).result
    }
}

/// Pour une fonction qui ne prend pas d'argument.
public struct NoPayload: Encodable, Sendable {
    public init() {}
}

// MARK: - Enveloppes du format onCall

struct CallableRequest<Payload: Encodable & Sendable>: Encodable, Sendable {
    let data: Payload
}

struct CallableResponse<Result: Decodable>: Decodable {
    let result: Result
}
