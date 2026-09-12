import Foundation

/// Une authentification qui ne quitte jamais le processus.
///
/// Elle honore le même contrat que le vrai service, **flux d'état compris**, ce qui permet
/// de tester un parcours de connexion entier — erreurs, reconnexion, liaison de compte
/// anonyme — sans projet Firebase et sans réseau.
public actor InMemoryAuth: AuthClient {

    private struct Account {
        var user: AuthUser
        var password: String?
        /// Dernière preuve d'identité. Ce qui suit une opération sensible.
        var lastAuthenticated: Date
    }

    private var accounts: [String: Account] = [:]          // par e-mail
    private var anonymous: [String: Account] = [:]         // par identifiant
    private var currentID: String?
    private var state: AuthState = .signedOut
    private var continuations: [UUID: AsyncStream<AuthState>.Continuation] = [:]
    private var nextError: AuthFailure?

    /// Au-delà de cette ancienneté, une opération sensible exige une reconnexion.
    ///
    /// Firebase utilise cinq minutes. Le double le reproduit pour que le chemin
    /// `requiresRecentLogin` soit testable — c'est celui qu'on oublie le plus.
    public var recentLoginWindow: Duration = .seconds(300)

    public init(state: AuthState = .signedOut) {
        self.state = state
        if case let .signedIn(user) = state {
            currentID = user.id
            anonymous[user.id] = Account(user: user, password: nil, lastAuthenticated: .now)
        }
    }

    /// Fait échouer le prochain appel.
    public func failNextCall(with error: AuthFailure) {
        nextError = error
    }

    /// Fait comme si la dernière connexion datait — pour tester `requiresRecentLogin`.
    public func ageCurrentSession(by duration: Duration) {
        guard let id = currentID else { return }
        let shift = -Double(duration.components.seconds)
        if let email = accounts.first(where: { $0.value.user.id == id })?.key {
            accounts[email]?.lastAuthenticated.addTimeInterval(shift)
        } else {
            anonymous[id]?.lastAuthenticated.addTimeInterval(shift)
        }
    }

    // MARK: - État

    public func stateChanges() -> AsyncStream<AuthState> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            // L'état courant part immédiatement : un abonné ne doit pas attendre le
            // prochain changement pour savoir où il en est.
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    public func currentUser() -> AuthUser? { state.user }

    // MARK: - Connexion

    public func signIn(email: String, password: String) throws(AuthFailure) -> AuthUser {
        try consumeScheduledError()
        guard var account = accounts[email], account.password == password else {
            throw .invalidCredentials
        }
        account.lastAuthenticated = .now
        accounts[email] = account
        return publish(account.user)
    }

    public func signUp(email: String, password: String) throws(AuthFailure) -> AuthUser {
        try consumeScheduledError()
        guard email.contains("@") else { throw .invalidEmail(email) }
        guard accounts[email] == nil else { throw .emailAlreadyInUse(email) }
        guard password.count >= 6 else {
            throw .weakPassword(reason: "au moins six caractères")
        }

        let user = AuthUser(
            id: UUID().uuidString,
            email: email,
            isEmailVerified: false,
            providers: [.password],
            createdAt: .now,
            lastSignInAt: .now
        )
        accounts[email] = Account(user: user, password: password, lastAuthenticated: .now)
        return publish(user)
    }

    public func signInAnonymously() throws(AuthFailure) -> AuthUser {
        try consumeScheduledError()
        let user = AuthUser(
            id: UUID().uuidString,
            isAnonymous: true,
            providers: [.anonymous],
            createdAt: .now,
            lastSignInAt: .now
        )
        anonymous[user.id] = Account(user: user, password: nil, lastAuthenticated: .now)
        return publish(user)
    }

    public func signIn(with credential: ProviderCredential) throws(AuthFailure) -> AuthUser {
        try consumeScheduledError()
        let email = "\(credential.provider.rawValue)-\(credential.idToken)@example.test"
        if var existing = accounts[email] {
            existing.lastAuthenticated = .now
            accounts[email] = existing
            return publish(existing.user)
        }
        let user = AuthUser(
            id: UUID().uuidString,
            email: email,
            isEmailVerified: true,
            providers: [credential.provider],
            createdAt: .now,
            lastSignInAt: .now
        )
        accounts[email] = Account(user: user, password: nil, lastAuthenticated: .now)
        return publish(user)
    }

    public func signIn(customToken: String) throws(AuthFailure) -> AuthUser {
        try consumeScheduledError()
        let user = AuthUser(
            id: customToken,
            providers: [],
            createdAt: .now,
            lastSignInAt: .now
        )
        anonymous[user.id] = Account(user: user, password: nil, lastAuthenticated: .now)
        return publish(user)
    }

    public func signOut() throws(AuthFailure) {
        try consumeScheduledError()
        currentID = nil
        broadcast(.signedOut)
    }

    // MARK: - Jeton

    public func idToken(forceRefresh: Bool) throws(AuthFailure) -> String? {
        try consumeScheduledError()
        guard let user = state.user else { return nil }
        return "token-\(user.id)\(forceRefresh ? "-frais" : "")"
    }

    private var storedClaims: [String: AuthClaim] = [:]

    /// Pose des revendications, pour tester un parcours qui dépend d'un rôle.
    public func setClaims(_ claims: [String: AuthClaim]) {
        storedClaims = claims
    }

    public func claims() throws(AuthFailure) -> [String: AuthClaim] {
        try consumeScheduledError()
        guard state.user != nil else { throw .notSignedIn }
        return storedClaims
    }

    // MARK: - E-mail

    public func sendEmailVerification() throws(AuthFailure) {
        try consumeScheduledError()
        guard state.user != nil else { throw .notSignedIn }
    }

    public func sendPasswordReset(email: String) throws(AuthFailure) {
        try consumeScheduledError()
        guard accounts[email] != nil else { throw .userNotFound }
    }

    public func sendEmailChangeVerification(to newEmail: String) throws(AuthFailure) {
        try consumeScheduledError()
        guard state.user != nil else { throw .notSignedIn }
        guard newEmail.contains("@") else { throw .invalidEmail(newEmail) }
        guard accounts[newEmail] == nil else { throw .emailAlreadyInUse(newEmail) }
    }

    /// Simule le suivi du lien de vérification, dans un autre onglet.
    public func confirmEmailVerification() {
        guard let user = state.user, let email = user.email, var account = accounts[email] else { return }
        account.user = Self.copy(user, isEmailVerified: true)
        accounts[email] = account
        // Pas de diffusion : Firebase non plus ne prévient pas. C'est ce qui rend
        // `reloadUser()` nécessaire.
    }

    public func reloadUser() throws(AuthFailure) -> AuthUser {
        try consumeScheduledError()
        guard let id = currentID else { throw .notSignedIn }
        guard let account = account(for: id) else { throw .sessionExpired }
        return publish(account.user)
    }

    // MARK: - Compte

    public func updateProfile(displayName: String?, photoURL: URL?) throws(AuthFailure) -> AuthUser {
        try consumeScheduledError()
        guard let id = currentID, var account = account(for: id) else { throw .notSignedIn }
        account.user = Self.copy(account.user, displayName: displayName, photoURL: photoURL)
        store(account, for: id)
        return publish(account.user)
    }

    public func updatePassword(_ password: String) throws(AuthFailure) {
        try consumeScheduledError()
        try requireRecentLogin()
        guard password.count >= 6 else { throw .weakPassword(reason: "au moins six caractères") }
        guard let id = currentID,
              let email = accounts.first(where: { $0.value.user.id == id })?.key
        else { throw .notSignedIn }
        accounts[email]?.password = password
    }

    public func reauthenticate(password: String) throws(AuthFailure) {
        try consumeScheduledError()
        guard let id = currentID,
              let email = accounts.first(where: { $0.value.user.id == id })?.key,
              accounts[email]?.password == password
        else { throw .invalidCredentials }
        accounts[email]?.lastAuthenticated = .now
    }

    public func reauthenticate(with credential: ProviderCredential) throws(AuthFailure) {
        try consumeScheduledError()
        guard let id = currentID, var account = account(for: id) else { throw .notSignedIn }
        account.lastAuthenticated = .now
        store(account, for: id)
    }

    public func link(_ credential: ProviderCredential) throws(AuthFailure) -> AuthUser {
        try consumeScheduledError()
        guard let id = currentID, var account = account(for: id) else { throw .notSignedIn }
        guard !account.user.providers.contains(credential.provider) else {
            throw .providerAlreadyLinked(credential.provider)
        }
        // L'identifiant ne change pas : c'est tout l'intérêt, les données rattachées
        // survivent.
        account.user = Self.copy(
            account.user,
            isAnonymous: false,
            providers: account.user.providers.filter { $0 != .anonymous } + [credential.provider]
        )
        store(account, for: id)
        return publish(account.user)
    }

    public func unlink(_ provider: AuthProvider) throws(AuthFailure) -> AuthUser {
        try consumeScheduledError()
        guard let id = currentID, var account = account(for: id) else { throw .notSignedIn }
        account.user = Self.copy(
            account.user,
            providers: account.user.providers.filter { $0 != provider }
        )
        store(account, for: id)
        return publish(account.user)
    }

    public func deleteAccount() throws(AuthFailure) {
        try consumeScheduledError()
        try requireRecentLogin()
        guard let id = currentID else { throw .notSignedIn }
        accounts = accounts.filter { $0.value.user.id != id }
        anonymous.removeValue(forKey: id)
        currentID = nil
        broadcast(.signedOut)
    }

    // MARK: - Détail

    private func requireRecentLogin() throws(AuthFailure) {
        guard let id = currentID, let account = account(for: id) else { throw .notSignedIn }
        let age = Date.now.timeIntervalSince(account.lastAuthenticated)
        if age > Double(recentLoginWindow.components.seconds) {
            throw .requiresRecentLogin
        }
    }

    private func account(for id: String) -> Account? {
        accounts.first(where: { $0.value.user.id == id })?.value ?? anonymous[id]
    }

    private func store(_ account: Account, for id: String) {
        if let email = accounts.first(where: { $0.value.user.id == id })?.key {
            accounts[email] = account
        } else {
            anonymous[id] = account
        }
    }

    private func publish(_ user: AuthUser) -> AuthUser {
        currentID = user.id
        broadcast(.signedIn(user))
        return user
    }

    private func broadcast(_ newState: AuthState) {
        state = newState
        for continuation in continuations.values {
            continuation.yield(newState)
        }
    }

    private func consumeScheduledError() throws(AuthFailure) {
        if let error = nextError {
            nextError = nil
            throw error
        }
    }

    private static func copy(
        _ user: AuthUser,
        displayName: String?? = nil,
        photoURL: URL?? = nil,
        isEmailVerified: Bool? = nil,
        isAnonymous: Bool? = nil,
        providers: [AuthProvider]? = nil
    ) -> AuthUser {
        AuthUser(
            id: user.id,
            email: user.email,
            displayName: displayName ?? user.displayName,
            photoURL: photoURL ?? user.photoURL,
            phoneNumber: user.phoneNumber,
            isEmailVerified: isEmailVerified ?? user.isEmailVerified,
            isAnonymous: isAnonymous ?? user.isAnonymous,
            providers: providers ?? user.providers,
            createdAt: user.createdAt,
            lastSignInAt: user.lastSignInAt
        )
    }
}
