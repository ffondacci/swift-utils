import Foundation

/// Ce qui parle réellement au service d'authentification.
///
/// Le store ne voit que ce protocole : il ignore s'il s'adresse à Firebase Auth ou au
/// double en mémoire. C'est ce qui permet de tester tout le parcours de connexion d'une
/// app — y compris les erreurs — sans projet Firebase et sans le SDK.
public protocol AuthClient: Sendable {

    // MARK: - État

    /// Le flux des changements d'état.
    ///
    /// Émet l'état **courant** dès l'abonnement, puis chaque changement. C'est ce qui
    /// permet à une vue de se construire sans course entre son apparition et la
    /// restauration de session.
    func stateChanges() async -> AsyncStream<AuthState>

    /// L'utilisateur connecté, ou `nil`.
    func currentUser() async -> AuthUser?

    // MARK: - Connexion

    func signIn(email: String, password: String) async throws(AuthFailure) -> AuthUser
    func signUp(email: String, password: String) async throws(AuthFailure) -> AuthUser

    /// Crée un compte sans identifiants.
    ///
    /// Utile pour laisser essayer l'app avant l'inscription — mais un compte anonyme est
    /// perdu avec l'appareil. Le lier avant qu'il porte des données qui comptent.
    func signInAnonymously() async throws(AuthFailure) -> AuthUser

    /// Connexion par un fournisseur tiers, à partir d'identifiants obtenus par l'app.
    func signIn(with credential: ProviderCredential) async throws(AuthFailure) -> AuthUser

    /// Connexion par jeton personnalisé, émis par un backend de confiance.
    func signIn(customToken: String) async throws(AuthFailure) -> AuthUser

    func signOut() async throws(AuthFailure)

    // MARK: - Jeton

    /// Le jeton d'identité, à joindre aux appels d'API.
    ///
    /// - Parameter forceRefresh: `true` après un 401, pour ne pas resservir un jeton que
    ///   le serveur vient de refuser.
    func idToken(forceRefresh: Bool) async throws(AuthFailure) -> String?

    /// Les revendications personnalisées portées par le jeton — rôles, droits.
    ///
    /// Elles viennent du serveur et ne peuvent pas être falsifiées par le client. Mais
    /// elles ne sont rafraîchies qu'au renouvellement du jeton : après un changement de
    /// rôle, il faut un `idToken(forceRefresh: true)`.
    func claims() async throws(AuthFailure) -> [String: AuthClaim]

    // MARK: - E-mail

    /// Envoie le lien de vérification à l'adresse du compte.
    func sendEmailVerification() async throws(AuthFailure)

    /// Envoie un lien de réinitialisation de mot de passe.
    func sendPasswordReset(email: String) async throws(AuthFailure)

    /// Envoie un lien de confirmation vers la **nouvelle** adresse.
    ///
    /// L'adresse ne change qu'une fois le lien suivi — c'est ce qui empêche de détourner
    /// un compte en y mettant une adresse qu'on ne contrôle pas.
    func sendEmailChangeVerification(to newEmail: String) async throws(AuthFailure)

    /// Relit le profil depuis le serveur.
    ///
    /// Nécessaire pour voir `isEmailVerified` passer à vrai : le client ne l'apprend pas
    /// tout seul quand l'utilisateur suit le lien dans un autre onglet.
    func reloadUser() async throws(AuthFailure) -> AuthUser

    // MARK: - Compte

    func updateProfile(displayName: String?, photoURL: URL?) async throws(AuthFailure) -> AuthUser

    /// - Throws: ``AuthFailure/requiresRecentLogin`` si la session est trop ancienne.
    func updatePassword(_ password: String) async throws(AuthFailure)

    /// Reprouve l'identité, pour débloquer une opération sensible.
    func reauthenticate(password: String) async throws(AuthFailure)
    func reauthenticate(with credential: ProviderCredential) async throws(AuthFailure)

    /// Lie un fournisseur au compte courant.
    ///
    /// C'est ce qui transforme un compte anonyme en compte durable, sans perdre son `id`
    /// ni les données qui y sont rattachées.
    func link(_ credential: ProviderCredential) async throws(AuthFailure) -> AuthUser

    func unlink(_ provider: AuthProvider) async throws(AuthFailure) -> AuthUser

    /// - Throws: ``AuthFailure/requiresRecentLogin`` si la session est trop ancienne.
    func deleteAccount() async throws(AuthFailure)
}
