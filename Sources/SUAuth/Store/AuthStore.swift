import Foundation
import Observation
import SULogger

/// Le point d'entrée du module, et la seule chose que l'app manipule au quotidien.
///
/// Il s'abonne au flux d'état dès sa construction et le **publie** : une vue lit
/// `state` ou `user` et se redessine à chaque connexion ou déconnexion, sans rien câbler.
///
/// ```swift
/// @main
/// struct LensyApp: App {
///     private let auth = AuthStore(client: LiveAuth())
///
///     var body: some Scene {
///         WindowGroup { RootView() }.environment(auth)
///     }
/// }
///
/// struct RootView: View {
///     @Environment(AuthStore.self) private var auth
///
///     var body: some View {
///         switch auth.state {
///         case .unknown:          ProgressView()      // la session se restaure
///         case .signedOut:        SignInScreen()
///         case .signedIn(let u):  HomeScreen(user: u)
///         }
///     }
/// }
/// ```
///
/// > **Les trois cas, pas deux.** `unknown` n'est ni connecté ni déconnecté : c'est
/// > l'instant où Firebase restaure la session. Le confondre avec `signedOut` fait
/// > clignoter un écran de connexion devant quelqu'un qui était déjà connecté.
@MainActor
@Observable
public final class AuthStore {

    @ObservationIgnored private let client: any AuthClient
    @ObservationIgnored private var observation: Task<Void, Never>?

    /// L'état courant, observé.
    public private(set) var state: AuthState = .unknown

    /// La dernière erreur rencontrée, hors annulations.
    ///
    /// Elle n'est pas effacée par une opération réussie — voir ``clearLastError()``.
    public private(set) var lastError: AuthFailure?

    /// Vrai pendant qu'une opération est en cours — de quoi désactiver un bouton.
    public private(set) var isWorking = false

    /// L'utilisateur connecté, ou `nil`.
    public var user: AuthUser? { state.user }

    /// Vrai seulement pour un utilisateur connecté. `unknown` rend `false`, mais
    /// ``AuthState/isResolving`` le distingue d'une vraie déconnexion.
    public var isSignedIn: Bool { state.isSignedIn }

    public init(client: any AuthClient) {
        self.client = client
        // L'abonnement démarre tout de suite : un store qu'il faudrait penser à amorcer
        // resterait `unknown` pour toujours le jour où on l'oublie.
        observation = Task { [weak self] in
            guard let stream = await self?.client.stateChanges() else { return }
            for await state in stream {
                guard let self else { return }
                self.apply(state)
            }
        }
    }

    deinit {
        observation?.cancel()
    }

    /// Un store qui ne touche à rien, pour les previews SwiftUI et les tests.
    public static func inMemory(state: AuthState = .signedOut) -> AuthStore {
        AuthStore(client: InMemoryAuth(state: state))
    }

    /// Attend que l'état soit résolu — c'est-à-dire qu'il ne soit plus ``AuthState/unknown``.
    ///
    /// À utiliser pour un écran de démarrage qui doit savoir où envoyer l'utilisateur :
    ///
    /// ```swift
    /// .task {
    ///     await auth.waitUntilResolved()
    ///     showsSplash = false
    /// }
    /// ```
    ///
    /// Rend immédiatement si l'état est déjà connu.
    public func waitUntilResolved() async {
        guard state == .unknown else { return }
        await withCheckedContinuation { continuation in
            resolutionWaiters.append(continuation)
        }
    }

    @ObservationIgnored private var resolutionWaiters: [CheckedContinuation<Void, Never>] = []

    /// Publie un nouvel état.
    ///
    /// Appelée à deux endroits, et c'est voulu : par le flux, pour ce qui vient de
    /// l'extérieur (session révoquée, déconnexion depuis un autre appareil), et par chaque
    /// opération à son retour. Sans le second, une app qui lit `user` juste après un
    /// `signIn` réussi verrait encore l'état d'avant — le flux n'ayant pas encore été
    /// livré.
    private func apply(_ newState: AuthState) {
        guard newState != state else { return }
        state = newState

        let description = switch newState {
        case .unknown: "état en cours de résolution"
        case .signedOut: "déconnecté"
        case let .signedIn(user): "connecté — \(user.id)\(user.isAnonymous ? " (anonyme)" : "")"
        }
        Log.info(description, category: .auth)

        if newState != .unknown, !resolutionWaiters.isEmpty {
            let waiters = resolutionWaiters
            resolutionWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    // MARK: - Connexion

    @discardableResult
    public func signIn(email: String, password: String) async throws(AuthFailure) -> AuthUser {
        let user = try await tracked("connexion e-mail") { () async throws(AuthFailure) -> AuthUser in
            try await client.signIn(email: email, password: password)
        }
        apply(.signedIn(user))
        return user
    }

    @discardableResult
    public func signUp(email: String, password: String) async throws(AuthFailure) -> AuthUser {
        let user = try await tracked("création de compte") { () async throws(AuthFailure) -> AuthUser in
            try await client.signUp(email: email, password: password)
        }
        apply(.signedIn(user))
        return user
    }

    @discardableResult
    public func signInAnonymously() async throws(AuthFailure) -> AuthUser {
        let user = try await tracked("connexion anonyme") { () async throws(AuthFailure) -> AuthUser in
            try await client.signInAnonymously()
        }
        apply(.signedIn(user))
        return user
    }

    @discardableResult
    public func signIn(with credential: ProviderCredential) async throws(AuthFailure) -> AuthUser {
        let user = try await tracked("connexion \(credential.provider.rawValue)") { () async throws(AuthFailure) -> AuthUser in
            try await client.signIn(with: credential)
        }
        apply(.signedIn(user))
        return user
    }

    @discardableResult
    public func signIn(customToken: String) async throws(AuthFailure) -> AuthUser {
        let user = try await tracked("connexion par jeton") { () async throws(AuthFailure) -> AuthUser in
            try await client.signIn(customToken: customToken)
        }
        apply(.signedIn(user))
        return user
    }

    public func signOut() async throws(AuthFailure) {
        try await tracked("déconnexion") { () async throws(AuthFailure) in
            try await client.signOut()
        }
        apply(.signedOut)
    }

    // MARK: - Jeton

    /// Le jeton d'identité, à joindre aux appels d'API.
    ///
    /// C'est ce qui relie ce module à `SUNetworking` :
    ///
    /// ```swift
    /// struct FirebaseTokens: TokenProvider {
    ///     let auth: AuthStore
    ///     func token(forceRefresh: Bool) async throws -> String? {
    ///         try await auth.idToken(forceRefresh: forceRefresh)
    ///     }
    /// }
    /// ```
    public func idToken(forceRefresh: Bool = false) async throws(AuthFailure) -> String? {
        try await report("jeton") { () async throws(AuthFailure) -> String? in
            try await client.idToken(forceRefresh: forceRefresh)
        }
    }

    /// Les revendications personnalisées — rôles, droits.
    public func claims() async throws(AuthFailure) -> [String: AuthClaim] {
        try await report("revendications") { () async throws(AuthFailure) -> [String: AuthClaim] in
            try await client.claims()
        }
    }

    // MARK: - E-mail

    public func sendEmailVerification() async throws(AuthFailure) {
        try await tracked("envoi de vérification") { () async throws(AuthFailure) in
            try await client.sendEmailVerification()
        }
    }

    public func sendPasswordReset(email: String) async throws(AuthFailure) {
        try await tracked("réinitialisation de mot de passe") { () async throws(AuthFailure) in
            try await client.sendPasswordReset(email: email)
        }
    }

    public func sendEmailChangeVerification(to newEmail: String) async throws(AuthFailure) {
        try await tracked("changement d'adresse") { () async throws(AuthFailure) in
            try await client.sendEmailChangeVerification(to: newEmail)
        }
    }

    /// Relit le profil depuis le serveur.
    ///
    /// À appeler au retour au premier plan quand on attend une vérification d'e-mail :
    /// le client n'apprend pas tout seul que l'utilisateur a suivi le lien.
    @discardableResult
    public func reload() async throws(AuthFailure) -> AuthUser {
        let user = try await tracked("relecture du profil") { () async throws(AuthFailure) -> AuthUser in
            try await client.reloadUser()
        }
        apply(.signedIn(user))
        return user
    }

    // MARK: - Compte

    @discardableResult
    public func updateProfile(
        displayName: String? = nil,
        photoURL: URL? = nil
    ) async throws(AuthFailure) -> AuthUser {
        let user = try await tracked("mise à jour du profil") { () async throws(AuthFailure) -> AuthUser in
            try await client.updateProfile(displayName: displayName, photoURL: photoURL)
        }
        apply(.signedIn(user))
        return user
    }

    public func updatePassword(_ password: String) async throws(AuthFailure) {
        try await tracked("changement de mot de passe") { () async throws(AuthFailure) in
            try await client.updatePassword(password)
        }
    }

    public func reauthenticate(password: String) async throws(AuthFailure) {
        try await tracked("reconnexion") { () async throws(AuthFailure) in
            try await client.reauthenticate(password: password)
        }
    }

    public func reauthenticate(with credential: ProviderCredential) async throws(AuthFailure) {
        try await tracked("reconnexion \(credential.provider.rawValue)") { () async throws(AuthFailure) in
            try await client.reauthenticate(with: credential)
        }
    }

    /// Lie un fournisseur au compte courant, sans changer son identifiant.
    ///
    /// C'est ce qui transforme un compte anonyme en compte durable : les données déjà
    /// rattachées à l'`id` restent en place.
    @discardableResult
    public func link(_ credential: ProviderCredential) async throws(AuthFailure) -> AuthUser {
        let user = try await tracked("liaison \(credential.provider.rawValue)") { () async throws(AuthFailure) -> AuthUser in
            try await client.link(credential)
        }
        apply(.signedIn(user))
        return user
    }

    @discardableResult
    public func unlink(_ provider: AuthProvider) async throws(AuthFailure) -> AuthUser {
        let user = try await tracked("déliaison \(provider.rawValue)") { () async throws(AuthFailure) -> AuthUser in
            try await client.unlink(provider)
        }
        apply(.signedIn(user))
        return user
    }

    public func deleteAccount() async throws(AuthFailure) {
        try await tracked("suppression du compte") { () async throws(AuthFailure) in
            try await client.deleteAccount()
        }
        apply(.signedOut)
    }

    /// Oublie la dernière erreur, une fois qu'elle a été montrée.
    public func clearLastError() {
        lastError = nil
    }

    // MARK: - Suivi

    private func tracked<T>(
        _ label: @autoclosure () -> String,
        _ operation: () async throws(AuthFailure) -> T
    ) async throws(AuthFailure) -> T {
        isWorking = true
        defer { isWorking = false }
        return try await report(label(), operation)
    }

    private func report<T>(
        _ label: @autoclosure () -> String,
        _ operation: () async throws(AuthFailure) -> T
    ) async throws(AuthFailure) -> T {
        do {
            let result = try await operation()
            Log.debug(label(), category: .auth)
            return result
        } catch {
            if error != .cancelled { lastError = error }
            Log.error("\(label()) — \(error)", category: .auth)
            throw error
        }
    }
}
