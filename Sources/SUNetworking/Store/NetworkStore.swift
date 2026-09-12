import Foundation
import Observation

/// Le point d'entrée du module, et la seule chose que l'app manipule au quotidien.
///
/// Il se place au-dessus des couches — client, middlewares, transport — et n'en expose
/// aucune. Sa signature ne mentionne ni `URLSession`, ni `URLRequest`, ni `Data` :
/// changer de transport ne change rien au code appelant.
///
/// ## Pourquoi pas de `shared`
///
/// Contrairement à `PersistenceStore`, ce store n'a **pas** d'instance partagée. Un store
/// réseau a besoin d'un `APIEnvironment` — les URL de base de vos services — que seule
/// l'app connaît. Un singleton sans environnement ne pourrait que planter au premier
/// appel, ou mentir. Construisez-le au démarrage et injectez-le.
///
/// ```swift
/// @main
/// struct LensyApp: App {
///     private let network = NetworkStore(
///         environment: .production,
///         middlewares: [
///             DefaultHeadersMiddleware(["Accept": "application/json"]),
///             TokenMiddleware(provider: FirebaseTokenProvider()),
///             RetryMiddleware(),
///         ]
///     )
///
///     var body: some Scene {
///         WindowGroup { RootView() }
///             .environment(network)
///     }
/// }
/// ```
///
/// ```swift
/// struct ProfileView: View {
///     @Environment(NetworkStore.self) private var network
///     @State private var profile: Profile?
///
///     var body: some View {
///         content
///             .overlay { if network.isLoading { ProgressView() } }
///             .task {
///                 profile = try? await network.send(FetchProfile(userID: "42"))
///             }
///     }
/// }
/// ```
@MainActor
@Observable
public final class NetworkStore {

    @ObservationIgnored private let client: any APIClient

    /// Le nombre de requêtes en cours. Observé : de quoi piloter un indicateur global.
    public private(set) var inFlightCount = 0

    /// La dernière erreur rencontrée, hors annulations.
    ///
    /// Elle n'est **pas** effacée par une requête qui réussit : une bannière d'erreur ne
    /// doit pas disparaître parce qu'un appel sans rapport a abouti entre-temps. Appelez
    /// ``clearLastError()`` quand l'utilisateur l'a vue.
    public private(set) var lastError: NetworkError?

    /// Vrai dès qu'une requête est en vol.
    public var isLoading: Bool { inFlightCount > 0 }

    /// Construit un store sur un client quelconque — y compris un double de test.
    public init(client: any APIClient) {
        self.client = client
    }

    /// Construit un store sur la pile HTTP standard.
    ///
    /// - Parameters:
    ///   - environment: les URL de base de vos services.
    ///   - transport: `URLSession` par défaut ; ``MockTransport`` en test.
    ///   - middlewares: dans l'ordre, du plus extérieur au plus proche du transport.
    ///     ``RetryMiddleware`` se place **après** ``TokenMiddleware``, pour que chaque
    ///     tentative reparte avec un jeton valide.
    ///   - defaultPolicy: le timeout et la politique de reprise par défaut.
    public convenience init(
        environment: APIEnvironment,
        transport: any Transport = URLSessionTransport(),
        middlewares: [any Middleware] = [],
        defaultPolicy: RequestPolicy = .default
    ) {
        self.init(client: PipelineClient(
            transport: transport,
            environment: environment,
            middlewares: middlewares,
            defaultPolicy: defaultPolicy
        ))
    }

    // MARK: - Envoi

    /// Exécute l'endpoint et rend sa réponse décodée.
    ///
    /// - Throws: ``NetworkError``. Le cas ``NetworkError/cancelled`` n'alimente pas
    ///   ``lastError`` — une vue qui disparaît n'est pas une panne.
    @discardableResult
    public func send<E: Endpoint>(_ endpoint: E) async throws(NetworkError) -> E.Response {
        inFlightCount += 1
        defer { inFlightCount -= 1 }

        do {
            return try await client.send(endpoint)
        } catch {
            if error != .cancelled { lastError = error }
            throw error
        }
    }

    // MARK: - Annulation

    /// Annule les requêtes en cours d'un service.
    public func cancel(service: APIService) {
        client.cancel(service: service)
    }

    /// Annule toutes les requêtes en cours.
    public func cancelAll() {
        client.cancelAll()
    }

    /// Oublie la dernière erreur, une fois qu'elle a été montrée.
    public func clearLastError() {
        lastError = nil
    }
}
