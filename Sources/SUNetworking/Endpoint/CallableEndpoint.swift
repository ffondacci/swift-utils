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
        // Une fonction qui ne rend rien répond `{"result": null}`, que le décodage d'un
        // type concret refuserait. Le court-circuit est ici plutôt que dans une extension
        // `where Response == NoResult` : une telle extension n'est retenue comme témoin
        // que pour un type concret, pas pour `Callable`, ce qui donnerait deux
        // comportements au même type.
        if let nothing = NoResult() as? Response { return nothing }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CallableResponse<Response>.self, from: data).result
    }

    /// Traduit l'enveloppe d'erreur du format `onCall`.
    ///
    /// Une fonction qui lève une `HttpsError` répond hors 2xx — 403 pour
    /// `permission-denied`, 401 pour `unauthenticated` — avec
    /// `{"error":{"message":…,"status":…}}`. Le message et le code remontent donc typés
    /// dans ``NetworkError/serviceFailed(context:code:message:)``, au lieu d'un corps JSON
    /// que chaque appelant devrait parser.
    ///
    /// Un corps qui n'a pas cette forme rend `nil` : le client produit alors son erreur
    /// générique, sans rien masquer.
    func mapError(_ data: Data, statusCode: Int) -> NetworkError? {
        guard let envelope = try? JSONDecoder().decode(CallableFailure.self, from: data) else {
            return nil
        }
        return .serviceFailed(
            context: NetworkErrorContext(
                method: method.rawValue,
                url: path,
                statusCode: statusCode,
                responseBody: String(data: data, encoding: .utf8)
            ),
            code: envelope.error.status,
            message: envelope.error.message
        )
    }
}

/// Pour une fonction qui ne rend rien.
///
/// Le format `onCall` répond alors `{"result": null}`, que le décodage d'un type concret
/// refuserait. Ce type absorbe le cas :
///
/// ```swift
/// let _: NoResult = try await network.send(Callable("markAsRead", payload: id))
/// ```
///
/// Le corps de la réponse n'est jamais lu : `{"result": null}`, un objet, ou rien du tout
/// conviennent tous.
public struct NoResult: Decodable, Sendable {
    public init() {}
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

struct CallableFailure: Decodable {
    struct Failure: Decodable {
        let message: String
        let status: String
    }
    let error: Failure
}
