import Foundation

/// Toutes les erreurs que `SUAuth` peut produire.
///
/// > Le nom suit `StorageFailure` plutôt que `AuthError` : `AuthErrorCode` existe dans
/// > `FirebaseAuth`, et un `AuthError` de notre côté inviterait la confusion.
///
/// Les codes du SDK sont traduits en cas nommés parce qu'une app en fait des choses très
/// différentes : un mot de passe faible se corrige dans le formulaire, une session trop
/// ancienne demande de se reconnecter, une panne réseau demande d'attendre.
public enum AuthFailure: Error, Sendable, Equatable {

    /// L'e-mail ou le mot de passe ne correspondent à rien.
    ///
    /// Firebase ne distingue plus « e-mail inconnu » de « mauvais mot de passe » — c'est
    /// volontaire de leur part : le distinguer permettrait d'énumérer les comptes.
    case invalidCredentials

    /// L'adresse n'est pas une adresse e-mail valide.
    case invalidEmail(String)

    /// Un compte existe déjà avec cette adresse.
    case emailAlreadyInUse(String)

    /// Le mot de passe ne satisfait pas la politique du projet.
    case weakPassword(reason: String)

    /// Le compte a été désactivé côté console.
    case userDisabled

    /// Aucun compte pour cette adresse — sur les opérations qui le distinguent encore,
    /// comme la réinitialisation de mot de passe.
    case userNotFound

    /// **L'opération exige une connexion récente.**
    ///
    /// Firebase l'impose pour tout ce qui est sensible : changer d'e-mail, de mot de
    /// passe, supprimer le compte. La parade est ``AuthStore/reauthenticate(with:)``,
    /// puis on rejoue l'opération.
    case requiresRecentLogin

    /// Un compte existe déjà avec cette adresse, mais chez un autre fournisseur.
    ///
    /// Le cas typique : l'utilisateur s'était inscrit par e-mail et essaie « Continuer
    /// avec Google ». L'app doit lui proposer de lier les deux comptes.
    case accountExistsWithDifferentProvider(email: String?)

    /// Les identifiants du fournisseur sont invalides ou expirés.
    case invalidProviderCredential(provider: AuthProvider, reason: String)

    /// Ce fournisseur n'est pas activé dans la console Firebase.
    case providerNotEnabled(AuthProvider)

    /// Ce fournisseur est déjà lié à ce compte.
    case providerAlreadyLinked(AuthProvider)

    /// Trop de tentatives. Firebase a temporairement bloqué.
    case tooManyRequests

    /// Le service est injoignable.
    case networkUnavailable(reason: String)

    /// Aucun utilisateur connecté, alors que l'opération en exigeait un.
    case notSignedIn

    /// Le jeton a expiré et n'a pas pu être renouvelé — session révoquée, compte supprimé.
    case sessionExpired

    /// L'opération a été annulée.
    case cancelled

    /// Un code que le module ne connaît pas encore, avec de quoi le diagnostiquer.
    case unknown(code: Int, reason: String)

    /// Indique si réessayer plus tard a une chance d'aboutir.
    public var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .tooManyRequests: true
        default: false
        }
    }

    /// Indique si l'app doit demander à l'utilisateur de se reconnecter avant de rejouer.
    public var requiresReauthentication: Bool {
        switch self {
        case .requiresRecentLogin, .sessionExpired: true
        default: false
        }
    }

    /// Indique si l'erreur se corrige dans le formulaire, sans rien relancer.
    ///
    /// C'est ce qui permet d'afficher un message sous le champ concerné au lieu d'une
    /// alerte générique.
    public var isUserCorrectable: Bool {
        switch self {
        case .invalidCredentials, .invalidEmail, .emailAlreadyInUse, .weakPassword: true
        default: false
        }
    }
}

extension AuthFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidCredentials: "Identifiants incorrects"
        case let .invalidEmail(email): "Adresse invalide : « \(email) »"
        case let .emailAlreadyInUse(email): "Un compte existe déjà pour « \(email) »"
        case let .weakPassword(reason): "Mot de passe trop faible : \(reason)"
        case .userDisabled: "Ce compte a été désactivé"
        case .userNotFound: "Aucun compte pour cette adresse"
        case .requiresRecentLogin: "Opération sensible — reconnexion requise"
        case let .accountExistsWithDifferentProvider(email):
            email.map { "« \($0) » est déjà lié à un autre mode de connexion" }
                ?? "Cette adresse est déjà liée à un autre mode de connexion"
        case let .invalidProviderCredential(provider, reason):
            "Identifiants \(provider.rawValue) refusés : \(reason)"
        case let .providerNotEnabled(provider):
            "\(provider.rawValue) n'est pas activé dans la console Firebase"
        case let .providerAlreadyLinked(provider): "\(provider.rawValue) est déjà lié à ce compte"
        case .tooManyRequests: "Trop de tentatives — réessayez plus tard"
        case let .networkUnavailable(reason): "Service injoignable : \(reason)"
        case .notSignedIn: "Aucun utilisateur connecté"
        case .sessionExpired: "Session expirée"
        case .cancelled: "Opération annulée"
        case let .unknown(code, reason): "Erreur d'authentification \(code) : \(reason)"
        }
    }
}
