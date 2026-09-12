import Foundation
import SULogger
import Testing
@testable import SUAuth

@MainActor
@Suite("Authentification")
struct AuthStoreTests {

    private func makeStore(_ state: AuthState = .signedOut) async -> (AuthStore, InMemoryAuth) {
        let client = InMemoryAuth(state: state)
        let store = AuthStore(client: client)
        await store.waitUntilResolved()
        return (store, client)
    }

    // MARK: - L'état, et le piège du démarrage

    @Test("l'état part d'inconnu, puis se résout")
    func stateResolvesFromUnknown() async {
        let store = AuthStore(client: InMemoryAuth(state: .signedOut))

        // Avant la première réponse : ni connecté, ni déconnecté.
        #expect(store.state == .unknown)
        #expect(store.state.isResolving)
        #expect(store.isSignedIn == false)

        await store.waitUntilResolved()
        #expect(store.state == .signedOut)
        #expect(store.state.isResolving == false)
    }

    @Test("une session restaurée arrive connectée, sans passer par déconnecté")
    func restoredSessionDoesNotFlicker() async {
        let user = AuthUser(id: "u1", email: "a@b.c")
        let store = AuthStore(client: InMemoryAuth(state: .signedIn(user)))

        await store.waitUntilResolved()

        // Le piège classique : traiter `unknown` comme `signedOut` ferait clignoter un
        // écran de connexion devant quelqu'un qui était déjà connecté.
        #expect(store.user?.id == "u1")
    }

    // MARK: - Connexion

    @Test("un compte créé se reconnecte avec les mêmes identifiants")
    func signUpThenSignIn() async throws {
        let (store, _) = await makeStore()

        let created = try await store.signUp(email: "a@b.c", password: "motdepasse")
        try await store.signOut()
        let again = try await store.signIn(email: "a@b.c", password: "motdepasse")

        #expect(created.id == again.id)
        #expect(store.isSignedIn)
    }

    @Test("un mauvais mot de passe échoue sans changer l'état")
    func wrongPasswordKeepsState() async throws {
        let (store, _) = await makeStore()
        _ = try await store.signUp(email: "a@b.c", password: "motdepasse")
        try await store.signOut()

        let error = await #expect(throws: AuthFailure.self) {
            try await store.signIn(email: "a@b.c", password: "faux")
        }

        #expect(error == .invalidCredentials)
        #expect(error?.isUserCorrectable == true, "ça se corrige dans le formulaire")
        #expect(store.isSignedIn == false)
        #expect(store.lastError == .invalidCredentials)
    }

    @Test("une adresse déjà prise est refusée")
    func duplicateEmailIsRefused() async throws {
        let (store, _) = await makeStore()
        _ = try await store.signUp(email: "a@b.c", password: "motdepasse")

        let error = await #expect(throws: AuthFailure.self) {
            try await store.signUp(email: "a@b.c", password: "autrechose")
        }

        #expect(error == .emailAlreadyInUse("a@b.c"))
    }

    @Test("un mot de passe trop court est refusé avant tout appel")
    func weakPasswordIsRefused() async throws {
        let (store, _) = await makeStore()

        let error = await #expect(throws: AuthFailure.self) {
            try await store.signUp(email: "a@b.c", password: "court")
        }

        guard case .weakPassword = error else {
            Issue.record("attendu .weakPassword, reçu \(String(describing: error))")
            return
        }
    }

    @Test("la déconnexion repasse l'état à déconnecté")
    func signOutClearsState() async throws {
        let (store, _) = await makeStore()
        _ = try await store.signUp(email: "a@b.c", password: "motdepasse")

        try await store.signOut()

        #expect(store.state == .signedOut)
        #expect(store.user == nil)
    }

    // MARK: - Le compte anonyme, et sa liaison

    @Test("lier un compte anonyme garde son identifiant")
    func linkingAnonymousKeepsIdentity() async throws {
        let (store, _) = await makeStore()
        let anonymous = try await store.signInAnonymously()
        #expect(anonymous.isAnonymous)

        let linked = try await store.link(
            ProviderCredential(provider: .apple, idToken: "jeton-apple", rawNonce: "nonce")
        )

        // C'est tout l'intérêt : les données rattachées à cet identifiant survivent.
        #expect(linked.id == anonymous.id)
        #expect(linked.isAnonymous == false)
        #expect(linked.providers.contains(.apple))
    }

    @Test("lier deux fois le même fournisseur est refusé")
    func doubleLinkIsRefused() async throws {
        let (store, _) = await makeStore()
        _ = try await store.signInAnonymously()
        let credential = ProviderCredential(provider: .apple, idToken: "jeton")
        _ = try await store.link(credential)

        let error = await #expect(throws: AuthFailure.self) {
            try await store.link(credential)
        }

        #expect(error == .providerAlreadyLinked(.apple))
    }

    // MARK: - Les opérations sensibles

    @Test("une session trop ancienne bloque une opération sensible, la reconnexion débloque")
    func sensitiveOperationRequiresRecentLogin() async throws {
        let (store, client) = await makeStore()
        _ = try await store.signUp(email: "a@b.c", password: "motdepasse")
        await client.ageCurrentSession(by: .seconds(3_600))

        let error = await #expect(throws: AuthFailure.self) {
            try await store.updatePassword("nouveaumotdepasse")
        }
        #expect(error == .requiresRecentLogin)
        #expect(error?.requiresReauthentication == true)

        // La parade, et la seule.
        try await store.reauthenticate(password: "motdepasse")
        try await store.updatePassword("nouveaumotdepasse")

        try await store.signOut()
        _ = try await store.signIn(email: "a@b.c", password: "nouveaumotdepasse")
        #expect(store.isSignedIn)
    }

    @Test("supprimer un compte exige aussi une connexion récente")
    func deleteRequiresRecentLogin() async throws {
        let (store, client) = await makeStore()
        _ = try await store.signUp(email: "a@b.c", password: "motdepasse")
        await client.ageCurrentSession(by: .seconds(3_600))

        let error = await #expect(throws: AuthFailure.self) {
            try await store.deleteAccount()
        }

        #expect(error == .requiresRecentLogin)
        #expect(store.isSignedIn, "le compte est intact")
    }

    @Test("un compte supprimé déconnecte et ne se reconnecte plus")
    func deletedAccountIsGone() async throws {
        let (store, _) = await makeStore()
        _ = try await store.signUp(email: "a@b.c", password: "motdepasse")

        try await store.deleteAccount()

        #expect(store.state == .signedOut)
        let error = await #expect(throws: AuthFailure.self) {
            try await store.signIn(email: "a@b.c", password: "motdepasse")
        }
        #expect(error == .invalidCredentials)
    }

    // MARK: - Vérification d'e-mail

    @Test("la vérification d'e-mail n'est visible qu'après relecture")
    func emailVerificationNeedsReload() async throws {
        let (store, client) = await makeStore()
        _ = try await store.signUp(email: "a@b.c", password: "motdepasse")
        try await store.sendEmailVerification()

        // L'utilisateur suit le lien ailleurs — le client ne l'apprend pas tout seul.
        await client.confirmEmailVerification()
        #expect(store.user?.isEmailVerified == false)

        let reloaded = try await store.reload()
        #expect(reloaded.isEmailVerified)
        #expect(store.user?.isEmailVerified == true)
    }

    // MARK: - Jeton

    @Test("le jeton n'existe que connecté, et se rafraîchit sur demande")
    func tokenFollowsSession() async throws {
        let (store, _) = await makeStore()
        #expect(try await store.idToken() == nil)

        _ = try await store.signUp(email: "a@b.c", password: "motdepasse")
        let normal = try await store.idToken()
        let refreshed = try await store.idToken(forceRefresh: true)

        #expect(normal != nil)
        #expect(normal != refreshed, "un rafraîchissement forcé ne resert pas le même jeton")
    }

    @Test("les revendications exigent une session")
    func claimsRequireSignIn() async throws {
        let (store, client) = await makeStore()

        _ = await #expect(throws: AuthFailure.self) { try await store.claims() }

        _ = try await store.signUp(email: "a@b.c", password: "motdepasse")
        await client.setClaims(["role": .string("admin"), "pro": .bool(true)])

        let claims = try await store.claims()
        #expect(claims["role"]?.stringValue == "admin")
        #expect(claims["pro"]?.boolValue == true)
    }

    // MARK: - Profil et traces

    @Test("le profil mis à jour est publié dans l'état")
    func profileUpdateIsPublished() async throws {
        let (store, _) = await makeStore()
        _ = try await store.signUp(email: "a@b.c", password: "motdepasse")

        _ = try await store.updateProfile(displayName: "Florent")

        #expect(store.user?.displayName == "Florent")
    }

    @Test("les changements d'état sont tracés dans la catégorie auth")
    func stateChangesAreLogged() async throws {
        let collector = CollectingDestination()

        await Log.withConfiguration(LogConfiguration(destinations: [collector])) {
            let (store, _) = await makeStore()
            _ = try? await store.signUp(email: "a@b.c", password: "motdepasse")
            try? await store.signOut()
        }

        let auth = collector.entries(for: .auth)
        #expect(auth.isEmpty == false)
        #expect(collector.contains("connecté"))
        #expect(collector.contains("déconnecté"))
    }
}
