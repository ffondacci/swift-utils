import Foundation
import OSLog

/// La destination par défaut : le système de log d'Apple.
///
/// C'est celle qui fait le gros du travail, et elle ne coûte rien — `OSLog` n'écrit que si
/// quelqu'un écoute, et son stockage est géré par le système. Les traces apparaissent dans
/// la console d'Xcode, dans Console.app, et dans `log stream --predicate` sur un appareil
/// branché.
///
/// Une `os.Logger` est créée par catégorie, une fois, et réutilisée : c'est ce qui permet
/// de filtrer par `subsystem` et `category` côté outils.
public struct OSLogDestination: LogDestination {

    private let loggers: [LogCategory: os.Logger]

    /// - Parameter subsystem: en général l'identifiant de bundle. Par défaut celui de
    ///   l'app, ou `com.swift-utils.logger` si aucun n'est disponible.
    public init(subsystem: String = Self.defaultSubsystem) {
        var loggers: [LogCategory: os.Logger] = [:]
        for category in LogCategory.allCases {
            loggers[category] = os.Logger(subsystem: subsystem, category: category.rawValue)
        }
        self.loggers = loggers
    }

    public static var defaultSubsystem: String {
        Bundle.main.bundleIdentifier ?? "com.swift-utils.logger"
    }

    public func write(_ entry: LogEntry) {
        guard let logger = loggers[entry.category] else { return }
        let text = "\(entry.file):\(entry.line) \(entry.function) — \(entry.message)"

        // `\(text, privacy: .public)` : sans ça, le système remplace le contenu par
        // <private> dès qu'on lit les journaux hors du débogueur — et on se retrouve avec
        // un journal illisible au moment précis où on en a besoin.
        switch entry.level {
        case .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .warning: logger.warning("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        case .fault: logger.fault("\(text, privacy: .public)")
        }
    }
}
