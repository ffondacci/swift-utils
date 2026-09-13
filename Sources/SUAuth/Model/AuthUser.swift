import Foundation

/// Le fournisseur qui a authentifié un compte.
///
/// Ouvert à dessein : Firebase en ajoute régulièrement, et un `enum` fermé obligerait à
/// republier le module à chaque fois.
public struct AuthProvider: RawRepresentable, Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(value) }

    public static let password: AuthProvider = "password"
    public static let anonymous: AuthProvider = "anonymous"
    public static let google: AuthProvider = "google.com"
    public static let apple: AuthProvider = "apple.com"
    public static let facebook: AuthProvider = "facebook.com"
    public static let github: AuthProvider = "github.com"
    public static let phone: AuthProvider = "phone"
    public static let emailLink: AuthProvider = "emailLink"
}

/// Un utilisateur authentifié.
///
/// Une **photographie**, pas une référence vivante : le SDK rend un objet mutable qui
/// change sous les pieds de l'appelant, ce qui rend une vue SwiftUI impossible à raisonner.
/// Ici, chaque changement produit une nouvelle valeur.
public struct AuthUser: Sendable, Equatable, Identifiable {

    /// L'identifiant Firebase. C'est lui qu'on stocke dans Firestore, jamais l'e-mail.
    public let id: String

    public let email: String?
    public let displayName: String?
    public let photoURL: URL?
    public let phoneNumber: String?

    /// Vrai une fois le lien de vérification suivi.
    ///
    /// Un compte non vérifié peut se connecter : c'est à l'app de décider ce qu'elle lui
    /// laisse faire.
    public let isEmailVerified: Bool

    /// Vrai pour un compte anonyme, créé sans identifiants.
    ///
    /// À lier à de vrais identifiants avant qu'il ne soit perdu — voir
    /// ``AuthStore/link(_:)``.
    public let isAnonymous: Bool

    /// Les fournisseurs liés à ce compte.
    public let providers: [AuthProvider]

    public let createdAt: Date?
    public let lastSignInAt: Date?

    public init(
        id: String,
        email: String? = nil,
        displayName: String? = nil,
        photoURL: URL? = nil,
        phoneNumber: String? = nil,
        isEmailVerified: Bool = false,
        isAnonymous: Bool = false,
        providers: [AuthProvider] = [],
        createdAt: Date? = nil,
        lastSignInAt: Date? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.photoURL = photoURL
        self.phoneNumber = phoneNumber
        self.isEmailVerified = isEmailVerified
        self.isAnonymous = isAnonymous
        self.providers = providers
        self.createdAt = createdAt
        self.lastSignInAt = lastSignInAt
    }
}

/// L'état d'authentification.
public enum AuthState: Sendable, Equatable {

    /// Avant la première réponse du service.
    ///
    /// **Distinct de ``signedOut``**, et c'est le piège classique : au lancement, Firebase
    /// met un instant à restaurer la session. Traiter cet instant comme « déconnecté »
    /// fait clignoter un écran de connexion devant un utilisateur déjà connecté.
    case unknown

    case signedOut
    case signedIn(AuthUser)

    public var user: AuthUser? {
        if case let .signedIn(user) = self { user } else { nil }
    }

    /// Vrai seulement pour ``signedIn``. `unknown` n'est pas connecté — mais n'est pas
    /// déconnecté non plus.
    public var isSignedIn: Bool { user != nil }

    /// Vrai tant que le service n'a pas répondu. C'est le moment d'afficher un écran
    /// d'attente, pas un écran de connexion.
    public var isResolving: Bool { self == .unknown }

    /// Connecté **avec un compte anonyme**.
    ///
    /// Déconnecté rend `false` : la question « dois-je proposer de créer un compte ? » n'a
    /// de sens que pour quelqu'un qui est déjà entré.
    public var isAnonymous: Bool { user?.isAnonymous == true }

    /// Connecté **avec un vrai compte**, lié à au moins un fournisseur.
    ///
    /// C'est la condition d'un écran de profil, d'un changement de mot de passe, de tout
    /// ce qui n'a pas de sens pour un compte anonyme.
    public var hasPermanentAccount: Bool {
        guard let user else { return false }
        return !user.isAnonymous
    }
}

/// Une revendication personnalisée, telle qu'elle arrive dans le jeton.
public enum AuthClaim: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)

    public var stringValue: String? { if case let .string(v) = self { v } else { nil } }
    public var boolValue: Bool? { if case let .bool(v) = self { v } else { nil } }
    public var intValue: Int? { if case let .int(v) = self { v } else { nil } }
}

/// Les identifiants d'un fournisseur tiers.
///
/// Le module ne dépend d'**aucun** SDK de connexion — ni Google, ni Apple. L'app obtient
/// un jeton par les moyens habituels (`ASAuthorizationController`, le SDK Google) et le
/// passe ici. C'est le même motif que `TokenProvider` dans `SUNetworking`.
///
/// ```swift
/// // Sign in with Apple
/// ProviderCredential(
///     provider: .apple,
///     idToken: identityToken,
///     rawNonce: nonce
/// )
/// ```
public struct ProviderCredential: Sendable, Equatable {

    public let provider: AuthProvider
    public let idToken: String

    /// Le jeton d'accès, quand le fournisseur en donne un (Google, Facebook).
    public let accessToken: String?

    /// Le nonce non haché, exigé par Sign in with Apple.
    public let rawNonce: String?

    public init(
        provider: AuthProvider,
        idToken: String,
        accessToken: String? = nil,
        rawNonce: String? = nil
    ) {
        self.provider = provider
        self.idToken = idToken
        self.accessToken = accessToken
        self.rawNonce = rawNonce
    }
}
