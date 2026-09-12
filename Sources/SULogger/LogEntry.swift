import Foundation

/// Une trace, telle qu'elle arrive à une destination.
public struct LogEntry: Sendable, Equatable {

    public let level: LogLevel
    public let category: LogCategory
    public let message: String
    public let timestamp: Date

    /// Le fichier d'origine, sans son chemin.
    public let file: String
    public let function: String
    public let line: Int

    public init(
        level: LogLevel,
        category: LogCategory,
        message: String,
        timestamp: Date = .now,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        self.level = level
        self.category = category
        self.message = message
        self.timestamp = timestamp
        // `#fileID` rend « Module/Fichier.swift » : on ne garde que le nom.
        self.file = file.split(separator: "/").last.map(String.init) ?? file
        self.function = function
        self.line = line
    }

    /// La forme texte d'une ligne, utilisée par les destinations fichier et console.
    ///
    /// Horodatage en ISO 8601 avec millisecondes : c'est ce qui permet de recoller deux
    /// journaux entre eux, et de trier sans ambiguïté.
    public var formatted: String {
        "\(timestamp.formatted(Self.timestampStyle)) \(level.symbol) [\(category.rawValue)] "
            + "\(file):\(line) \(function) — \(message)"
    }

    /// `ISO8601FormatStyle` plutôt qu'`ISO8601DateFormatter` : le premier est un type
    /// valeur donc `Sendable`, le second une classe mutable que la concurrence stricte
    /// refuse en propriété statique. Et il n'y a pas de coût caché — le style est copié,
    /// pas partagé.
    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

/// Où partent les traces.
///
/// Le module fournit ``OSLogDestination``. `SULoggerFile` ajoute l'écriture sur disque, et
/// une app peut en écrire une pour Crashlytics ou Sentry en implémentant ce protocole.
///
/// > `write(_:)` est appelée depuis n'importe quel contexte, y compris le main actor.
/// > Une destination qui fait de l'I/O doit donc la rendre non bloquante elle-même —
/// > c'est ce que fait celle de `SULoggerFile`.
public protocol LogDestination: Sendable {
    func write(_ entry: LogEntry)
}
