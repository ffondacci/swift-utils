import Foundation

/// Une Cloud Function appelable, réglable **au point d'appel**.
///
/// `CallableEndpoint` demande un type par fonction, ce qui est bien quand la fonction a
/// une identité — des arguments nommés, des valeurs calculées. Quand ce n'est pas le cas,
/// `Callable` évite la cérémonie : le nom, la charge utile, et le reste par défaut.
///
/// ```swift
/// let confirmation: Confirmation = try await network.send(
///     Callable("sendFeedback", payload: feedback)
/// )
/// ```
///
/// Et **tout est réglable**, un paramètre à la fois, sans renoncer aux autres défauts :
///
/// ```swift
/// let confirmation: Confirmation = try await network.send(
///     Callable(
///         "sendFeedback",
///         payload: feedback,
///         headers: ["X-Debug": "1"],
///         authentication: .optional,
///         policy: RequestPolicy(timeout: .seconds(5), retry: .disabled)
///     )
/// )
/// ```
///
/// Pour une fonction sans argument :
///
/// ```swift
/// let stats: Stats = try await network.send(Callable("dailyStats"))
/// ```
public struct Callable<Payload: Encodable & Sendable, Value: Decodable & Sendable>: CallableEndpoint {

    public typealias Response = Value

    public let functionName: String
    public let payload: Payload

    public var service: APIService
    public var method: HTTPMethod
    public var headers: [String: String]
    public var authentication: AuthRequirement
    public var policy: RequestPolicy?

    /// - Parameters:
    ///   - functionName: le nom de la fonction déployée.
    ///   - payload: ses arguments.
    ///   - returning: le type de retour, quand le contexte ne suffit pas à l'inférer.
    ///   - service: le service porteur. Par défaut ``APIService/cloudFunctions``.
    ///   - method: `POST`, comme l'exige le format `onCall`. Réglable pour un déploiement
    ///     atypique.
    ///   - headers: en-têtes propres à cet appel, en plus de ceux du client.
    ///   - authentication: obligatoire par défaut — une fonction appelable en exige
    ///     presque toujours.
    ///   - policy: timeout et reprise pour ce seul appel. `nil` reprend ceux du client.
    public init(
        _ functionName: String,
        payload: Payload,
        returning: Value.Type = Value.self,
        service: APIService = .cloudFunctions,
        method: HTTPMethod = .post,
        headers: [String: String] = [:],
        authentication: AuthRequirement = .required,
        policy: RequestPolicy? = nil
    ) {
        self.functionName = functionName
        self.payload = payload
        self.service = service
        self.method = method
        self.headers = headers
        self.authentication = authentication
        self.policy = policy
    }
}

public extension Callable where Payload == NoPayload {

    /// Une fonction sans argument.
    init(
        _ functionName: String,
        returning: Value.Type = Value.self,
        service: APIService = .cloudFunctions,
        method: HTTPMethod = .post,
        headers: [String: String] = [:],
        authentication: AuthRequirement = .required,
        policy: RequestPolicy? = nil
    ) {
        self.init(
            functionName,
            payload: NoPayload(),
            returning: returning,
            service: service,
            method: method,
            headers: headers,
            authentication: authentication,
            policy: policy
        )
    }
}
