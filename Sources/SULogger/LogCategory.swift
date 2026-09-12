import Foundation

/// Le domaine dont une trace parle.
///
/// Trois suffisent pour commencer. La catégorie n'est pas décorative : elle devient la
/// `category` d'`OSLog`, donc c'est elle qui permet de filtrer dans Console.app ou dans
/// `log stream` sans noyer ce qu'on cherche.
public enum LogCategory: String, Sendable, Hashable, CaseIterable {

    /// Tout ce qui ne relève ni du réseau ni du stockage : cycle de vie, navigation,
    /// décisions métier.
    case app

    /// Requêtes, réponses, authentification, reprises.
    case network

    /// Lectures et écritures **locales**, caches, migrations.
    case persistence

    /// Authentification : connexion, déconnexion, jetons, changements d'état.
    ///
    /// Séparée du reste parce que c'est la première chose qu'on relit quand un utilisateur
    /// dit « ça m'a déconnecté tout seul ».
    case auth

    /// Fichiers : téléversements, téléchargements, métadonnées.
    ///
    /// Séparée de ``network`` : un transfert de vingt méga-octets et un appel d'API n'ont
    /// ni la même durée, ni les mêmes échecs, et les mélanger rend les deux illisibles.
    case storage

    /// Firestore : documents, requêtes, lots, transactions, contention.
    ///
    /// Séparée de ``persistence`` à dessein — quand une donnée est fausse, la première
    /// question est « locale ou distante ? », et deux catégories y répondent d'un coup
    /// d'œil.
    case firestore
}

/// La gravité d'une trace.
///
/// L'ordre compte : un seuil `.warning` laisse passer les avertissements, les erreurs et
/// les fautes, et écarte le reste.
public enum LogLevel: Int, Sendable, Hashable, Comparable, CaseIterable {

    /// Le détail qui n'intéresse qu'en développement.
    case debug

    /// Ce qu'on veut voir dans une session normale.
    case info

    /// Quelque chose d'anormal mais dont l'app se remet.
    case warning

    /// Une opération a échoué.
    case error

    /// L'app est dans un état dont elle ne se remettra pas.
    case fault

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Le symbole utilisé dans les sorties texte.
    public var symbol: String {
        switch self {
        case .debug: "·"
        case .info: "›"
        case .warning: "⚠"
        case .error: "✗"
        case .fault: "☠"
        }
    }

    public var name: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        case .fault: "FAULT"
        }
    }
}
