import Foundation

/// Fournit le jeton d'authentification.
///
/// **Aucun SDK n'entre dans le module.** L'app implémente ce protocole avec ce qu'elle
/// veut — Firebase Auth, OAuth, un jeton en Keychain — et `SUNetworking` n'en sait rien.
/// C'est ce qui permet de tester toute la chaîne d'authentification avec un fournisseur
/// de trois lignes.
public protocol TokenProvider: Sendable {

    /// - Parameter forceRefresh: `true` après un 401, pour forcer un jeton frais plutôt
    ///   que de resservir celui que le serveur vient de refuser.
    /// - Returns: le jeton, ou `nil` si l'utilisateur n'est pas authentifié.
    func token(forceRefresh: Bool) async throws -> String?
}

/// Joint un jeton aux requêtes qui en demandent un, et rejoue une fois sur 401.
///
/// Générique par construction : `Authorization: Bearer <jeton>` par défaut, mais
/// n'importe quel en-tête et n'importe quel schéma conviennent. Un App Check se branche
/// avec la même classe, sur `X-Firebase-AppCheck` et sans schéma.
public struct TokenMiddleware: Middleware {

    private let provider: any TokenProvider
    private let header: String
    private let scheme: String?
    private let refreshesOnUnauthorized: Bool

    /// - Parameters:
    ///   - provider: d'où vient le jeton.
    ///   - header: l'en-tête à poser.
    ///   - scheme: le préfixe — `"Bearer"`, ou `nil` pour poser le jeton brut.
    ///   - refreshesOnUnauthorized: rejouer une fois avec un jeton rafraîchi si le
    ///     serveur répond 401. Un jeton expiré entre la lecture et l'arrivée de la
    ///     requête est un cas courant, pas une anomalie.
    public init(
        provider: any TokenProvider,
        header: String = "Authorization",
        scheme: String? = "Bearer",
        refreshesOnUnauthorized: Bool = true
    ) {
        self.provider = provider
        self.header = header
        self.scheme = scheme
        self.refreshesOnUnauthorized = refreshesOnUnauthorized
    }

    public func intercept(
        _ context: RequestContext,
        next: @escaping MiddlewareChain
    ) async throws(NetworkError) -> TransportResponse {
        guard context.authentication != .none else {
            return try await next(context)
        }

        guard let token = try await fetchToken(forceRefresh: false, for: context) else {
            // `.optional` : on part sans identité plutôt que d'échouer.
            return try await next(context)
        }

        let response = try await next(authenticated(context, with: token))

        guard response.statusCode == 401, refreshesOnUnauthorized else {
            return response
        }

        // Le jeton était peut-être expiré depuis quelques millisecondes. Un seul nouvel
        // essai : si le second échoue aussi, ce n'est plus une question de fraîcheur.
        guard let refreshed = try await fetchToken(forceRefresh: true, for: context) else {
            throw .unauthorized(context: context.errorContext)
        }

        let retried = try await next(authenticated(context, with: refreshed))
        guard retried.statusCode != 401 else {
            throw .unauthorized(context: context.errorContext)
        }
        return retried
    }

    private func authenticated(_ context: RequestContext, with token: String) -> RequestContext {
        var context = context
        context.request.headers[header] = scheme.map { "\($0) \(token)" } ?? token
        return context
    }

    /// - Returns: le jeton, ou `nil` quand l'endpoint tolère son absence.
    /// - Throws: `.tokenUnavailable` si l'endpoint exige un jeton et qu'il n'y en a pas.
    private func fetchToken(
        forceRefresh: Bool,
        for context: RequestContext
    ) async throws(NetworkError) -> String? {
        let token: String?
        do {
            token = try await provider.token(forceRefresh: forceRefresh)
        } catch {
            guard context.authentication == .required else { return nil }
            throw .tokenUnavailable(reason: "\(error)")
        }

        if token == nil, context.authentication == .required {
            throw .tokenUnavailable(reason: "aucun utilisateur authentifié")
        }
        return token
    }
}
