#if Firebase
import Foundation
import FirebaseAuth
import SUAuth

/// L'adaptateur qui parle au vrai Firebase Auth.
///
/// C'est le **seul** type du dépôt qui importe `FirebaseAuth`, et il ne le laisse pas
/// franchir sa frontière : aucun `User`, aucun `AuthCredential` n'apparaît dans sa surface
/// publique.
///
/// > Important : `FirebaseApp.configure()` doit avoir eu lieu **avant** de construire ce
/// > client. Ce module ne configure rien.
public struct LiveAuth: AuthClient {

    // `Auth` n'est pas annoté `Sendable` : le SDK compile en mode Swift 5. L'instance est
    // un singleton par app, immuable, et le SDK sérialise ses propres accès.
    nonisolated(unsafe) private let auth: Auth

    /// - Parameter emulator: pointer un émulateur local au lieu du vrai service.
    public init(emulator: Emulator? = nil) {
        let auth = Auth.auth()
        if let emulator {
            auth.useEmulator(withHost: emulator.host, port: emulator.port)
        }
        self.auth = auth
    }

    public struct Emulator: Sendable, Equatable {
        public var host: String
        public var port: Int

        public init(host: String = "127.0.0.1", port: Int = 9099) {
            self.host = host
            self.port = port
        }
    }

    // MARK: - État

    public func stateChanges() -> AsyncStream<AuthState> {
        AsyncStream { continuation in
            // Le handle du SDK n'est pas `Sendable` ; il ne sort pas de cette closure et
            // n'est lu qu'au retrait de l'écoute.
            nonisolated(unsafe) let handle = auth.addStateDidChangeListener { _, user in
                continuation.yield(user.map { .signedIn(Self.translate($0)) } ?? .signedOut)
            }
            continuation.onTermination = { _ in
                Auth.auth().removeStateDidChangeListener(handle)
            }
        }
    }

    public func currentUser() -> AuthUser? {
        auth.currentUser.map(Self.translate)
    }

    // MARK: - Connexion

    public func signIn(email: String, password: String) async throws(AuthFailure) -> AuthUser {
        do {
            return Self.translate(try await auth.signIn(withEmail: email, password: password).user)
        } catch {
            throw Self.translate(error)
        }
    }

    public func signUp(email: String, password: String) async throws(AuthFailure) -> AuthUser {
        do {
            return Self.translate(try await auth.createUser(withEmail: email, password: password).user)
        } catch {
            throw Self.translate(error)
        }
    }

    public func signInAnonymously() async throws(AuthFailure) -> AuthUser {
        do {
            return Self.translate(try await auth.signInAnonymously().user)
        } catch {
            throw Self.translate(error)
        }
    }

    public func signIn(with credential: ProviderCredential) async throws(AuthFailure) -> AuthUser {
        do {
            return Self.translate(try await auth.signIn(with: Self.translate(credential)).user)
        } catch {
            throw Self.translate(error)
        }
    }

    public func signIn(customToken: String) async throws(AuthFailure) -> AuthUser {
        do {
            return Self.translate(try await auth.signIn(withCustomToken: customToken).user)
        } catch {
            throw Self.translate(error)
        }
    }

    public func signOut() throws(AuthFailure) {
        do {
            try auth.signOut()
        } catch {
            throw Self.translate(error)
        }
    }

    // MARK: - Jeton

    public func idToken(forceRefresh: Bool) async throws(AuthFailure) -> String? {
        guard let user = auth.currentUser else { return nil }
        do {
            return try await user.getIDToken(forcingRefresh: forceRefresh)
        } catch {
            throw Self.translate(error)
        }
    }

    public func claims() async throws(AuthFailure) -> [String: AuthClaim] {
        guard let user = auth.currentUser else { throw .notSignedIn }
        do {
            let result = try await user.getIDTokenResult()
            return result.claims.reduce(into: [:]) { claims, entry in
                claims[entry.key] = Self.translate(entry.value)
            }
        } catch {
            throw Self.translate(error)
        }
    }

    // MARK: - E-mail

    public func sendEmailVerification() async throws(AuthFailure) {
        guard let user = auth.currentUser else { throw .notSignedIn }
        do {
            try await user.sendEmailVerification()
        } catch {
            throw Self.translate(error)
        }
    }

    public func sendPasswordReset(email: String) async throws(AuthFailure) {
        do {
            try await auth.sendPasswordReset(withEmail: email)
        } catch {
            throw Self.translate(error)
        }
    }

    public func sendEmailChangeVerification(to newEmail: String) async throws(AuthFailure) {
        guard let user = auth.currentUser else { throw .notSignedIn }
        do {
            try await user.sendEmailVerification(beforeUpdatingEmail: newEmail)
        } catch {
            throw Self.translate(error)
        }
    }

    public func reloadUser() async throws(AuthFailure) -> AuthUser {
        guard let user = auth.currentUser else { throw .notSignedIn }
        do {
            try await user.reload()
        } catch {
            throw Self.translate(error)
        }
        guard let refreshed = auth.currentUser else { throw .sessionExpired }
        return Self.translate(refreshed)
    }

    // MARK: - Compte

    public func updateProfile(displayName: String?, photoURL: URL?) async throws(AuthFailure) -> AuthUser {
        guard let user = auth.currentUser else { throw .notSignedIn }
        let request = user.createProfileChangeRequest()
        if let displayName { request.displayName = displayName }
        if let photoURL { request.photoURL = photoURL }
        do {
            try await request.commitChanges()
        } catch {
            throw Self.translate(error)
        }
        guard let refreshed = auth.currentUser else { throw .sessionExpired }
        return Self.translate(refreshed)
    }

    public func updatePassword(_ password: String) async throws(AuthFailure) {
        guard let user = auth.currentUser else { throw .notSignedIn }
        do {
            try await user.updatePassword(to: password)
        } catch {
            throw Self.translate(error)
        }
    }

    public func reauthenticate(password: String) async throws(AuthFailure) {
        guard let user = auth.currentUser else { throw .notSignedIn }
        guard let email = user.email else { throw .invalidCredentials }
        do {
            _ = try await user.reauthenticate(
                with: EmailAuthProvider.credential(withEmail: email, password: password)
            )
        } catch {
            throw Self.translate(error)
        }
    }

    public func reauthenticate(with credential: ProviderCredential) async throws(AuthFailure) {
        guard let user = auth.currentUser else { throw .notSignedIn }
        do {
            _ = try await user.reauthenticate(with: Self.translate(credential))
        } catch {
            throw Self.translate(error)
        }
    }

    public func link(_ credential: ProviderCredential) async throws(AuthFailure) -> AuthUser {
        guard let user = auth.currentUser else { throw .notSignedIn }
        do {
            return Self.translate(try await user.link(with: Self.translate(credential)).user)
        } catch {
            throw Self.translate(error)
        }
    }

    public func unlink(_ provider: AuthProvider) async throws(AuthFailure) -> AuthUser {
        guard let user = auth.currentUser else { throw .notSignedIn }
        do {
            return Self.translate(try await user.unlink(fromProvider: provider.rawValue))
        } catch {
            throw Self.translate(error)
        }
    }

    public func deleteAccount() async throws(AuthFailure) {
        guard let user = auth.currentUser else { throw .notSignedIn }
        do {
            try await user.delete()
        } catch {
            throw Self.translate(error)
        }
    }

    // MARK: - Conversions

    private static func translate(_ user: User) -> AuthUser {
        AuthUser(
            id: user.uid,
            email: user.email,
            displayName: user.displayName,
            photoURL: user.photoURL,
            phoneNumber: user.phoneNumber,
            isEmailVerified: user.isEmailVerified,
            isAnonymous: user.isAnonymous,
            providers: user.providerData.map { AuthProvider($0.providerID) },
            createdAt: user.metadata.creationDate,
            lastSignInAt: user.metadata.lastSignInDate
        )
    }

    private static func translate(_ credential: ProviderCredential) -> AuthCredential {
        if credential.provider == .password {
            return EmailAuthProvider.credential(
                withEmail: credential.idToken,
                password: credential.accessToken ?? ""
            )
        }
        return OAuthProvider.credential(
            providerID: providerID(for: credential.provider),
            idToken: credential.idToken,
            rawNonce: credential.rawNonce ?? "",
            accessToken: credential.accessToken
        )
    }

    /// Le SDK garde son initialiseur par chaîne privé : la correspondance est donc
    /// explicite, avec `.custom` pour ce qu'il ne nomme pas.
    private static func providerID(for provider: AuthProvider) -> AuthProviderID {
        switch provider {
        case .apple: .apple
        case .google: .google
        case .facebook: .facebook
        case .github: .gitHub
        case .phone: .phone
        case .password: .email
        default: .custom(provider.rawValue)
        }
    }

    private static func translate(_ value: Any) -> AuthClaim {
        switch value {
        case let value as Bool: .bool(value)
        case let value as Int: .int(value)
        case let value as Double: .double(value)
        default: .string("\(value)")
        }
    }

    /// Traduit les codes du SDK.
    ///
    /// Firebase ne distingue plus « e-mail inconnu » de « mauvais mot de passe » : les deux
    /// remontent en `invalidCredential`, pour empêcher l'énumération des comptes.
    private static func translate(_ error: any Error) -> AuthFailure {
        let nsError = error as NSError
        let reason = nsError.localizedDescription
        let email = nsError.userInfo[AuthErrorUserInfoEmailKey] as? String

        guard let code = AuthErrorCode(rawValue: nsError.code) else {
            return .unknown(code: nsError.code, reason: reason)
        }

        return switch code {
        // Firebase fusionne « e-mail inconnu » et « mauvais mot de passe » : les
        // distinguer permettrait d'énumérer les comptes.
        case .wrongPassword, .invalidCredential: .invalidCredentials
        case .invalidEmail: .invalidEmail(email ?? "")
        case .emailAlreadyInUse: .emailAlreadyInUse(email ?? "")
        case .weakPassword: .weakPassword(reason: reason)
        case .userDisabled: .userDisabled
        case .userNotFound: .userNotFound
        case .requiresRecentLogin: .requiresRecentLogin
        case .accountExistsWithDifferentCredential, .credentialAlreadyInUse:
            .accountExistsWithDifferentProvider(email: email)
        case .providerAlreadyLinked: .providerAlreadyLinked(AuthProvider("inconnu"))
        case .operationNotAllowed: .providerNotEnabled(AuthProvider("inconnu"))
        case .tooManyRequests: .tooManyRequests
        case .networkError: .networkUnavailable(reason: reason)
        case .userTokenExpired, .invalidUserToken: .sessionExpired
        case .nullUser: .notSignedIn
        default: .unknown(code: nsError.code, reason: reason)
        }
    }
}
#endif
