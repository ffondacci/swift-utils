import Foundation
import Synchronization

/// Ce qui gouverne le journal.
public struct LogConfiguration: Sendable {

    /// En dessous de ce niveau, rien n'est écrit — et le message n'est même pas construit.
    public var minimumLevel: LogLevel

    /// Les catégories retenues. En retirer une la fait disparaître entièrement, ce qui est
    /// pratique pour isoler un domaine bruyant.
    public var categories: Set<LogCategory>

    /// Où partent les traces. Vide = le journal ne fait rien.
    public var destinations: [any LogDestination]

    public init(
        minimumLevel: LogLevel = .debug,
        categories: Set<LogCategory> = Set(LogCategory.allCases),
        destinations: [any LogDestination] = [OSLogDestination()]
    ) {
        self.minimumLevel = minimumLevel
        self.categories = categories
        self.destinations = destinations
    }

    /// Le réglage courant d'un build de développement : tout, sur OSLog.
    public static let `default` = LogConfiguration()

    /// Rien du tout — pour les tests qui ne veulent pas de bruit.
    public static let silent = LogConfiguration(destinations: [])
}

/// Le journal de l'app.
///
/// Volontairement **nonisolated et synchrone** : on trace depuis n'importe où — un acteur,
/// le main actor, une closure de bas niveau — et personne ne devrait avoir à écrire
/// `await` pour laisser une trace. L'état est protégé par un `Mutex`, dont les accès sont
/// assez brefs pour que ce soit le bon outil.
///
/// ```swift
/// Log.configure(.default)
/// Log.info("session démarrée")
/// Log.error("échec de la requête : \(error)", category: .network)
/// ```
///
/// Le message est un `@autoclosure` : s'il est filtré par le niveau ou la catégorie, la
/// chaîne n'est **jamais construite**. Un `Log.debug("\(gros.description)")` en production
/// ne coûte donc rien.
public enum Log {

    private static let configuration = Mutex<LogConfiguration>(.default)

    /// Remplace le réglage courant. À appeler une fois au démarrage.
    public static func configure(_ newConfiguration: LogConfiguration) {
        configuration.withLock { $0 = newConfiguration }
    }

    /// Le réglage courant.
    public static var current: LogConfiguration {
        configuration.withLock { $0 }
    }

    /// Ajoute une destination sans toucher aux autres.
    public static func add(_ destination: any LogDestination) {
        configuration.withLock { $0.destinations.append(destination) }
    }

    // MARK: - Écriture

    public static func debug(
        _ message: @autoclosure () -> String,
        category: LogCategory = .app,
        file: String = #fileID, function: String = #function, line: Int = #line
    ) {
        write(.debug, category, message, file, function, line)
    }

    public static func info(
        _ message: @autoclosure () -> String,
        category: LogCategory = .app,
        file: String = #fileID, function: String = #function, line: Int = #line
    ) {
        write(.info, category, message, file, function, line)
    }

    public static func warning(
        _ message: @autoclosure () -> String,
        category: LogCategory = .app,
        file: String = #fileID, function: String = #function, line: Int = #line
    ) {
        write(.warning, category, message, file, function, line)
    }

    public static func error(
        _ message: @autoclosure () -> String,
        category: LogCategory = .app,
        file: String = #fileID, function: String = #function, line: Int = #line
    ) {
        write(.error, category, message, file, function, line)
    }

    public static func fault(
        _ message: @autoclosure () -> String,
        category: LogCategory = .app,
        file: String = #fileID, function: String = #function, line: Int = #line
    ) {
        write(.fault, category, message, file, function, line)
    }

    private static func write(
        _ level: LogLevel,
        _ category: LogCategory,
        _ message: () -> String,
        _ file: String, _ function: String, _ line: Int
    ) {
        // Le filtre d'abord, le message ensuite : c'est tout l'intérêt de l'autoclosure.
        let destinations = configuration.withLock { configuration -> [any LogDestination] in
            guard level >= configuration.minimumLevel,
                  configuration.categories.contains(category)
            else { return [] }
            return configuration.destinations
        }
        guard !destinations.isEmpty else { return }

        let entry = LogEntry(
            level: level,
            category: category,
            message: message(),
            file: file,
            function: function,
            line: line
        )
        for destination in destinations {
            destination.write(entry)
        }
    }
}
